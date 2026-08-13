import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


APP_PATH = Path(__file__).parents[1] / "ui" / "app.py"


class UiApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.state_dir = root / "state"
        self.state_dir.mkdir()
        self.settings = root / "settings.env"
        self.settings.write_text(
            'VCF_VERSION="9.1.0"\n'
            'SYNC_TARGETS="esx install upgrade patches"\n'
            'CRON_SCHEDULE="0 3 * * 0"\n'
            'VCFDT_VERSION="test-version"\n'
        )
        environment = {
            "STATE_DIR": str(self.state_dir),
            "SETTINGS_FILE": str(self.settings),
            "DEPOT_DIR": str(root / "depot"),
            "REDIS_HOST": "127.0.0.1",
            "REDIS_PORT": "1",
            "REDIS_PASSWORD_FILE": str(root / "missing-password"),
        }
        with mock.patch.dict(os.environ, environment):
            spec = importlib.util.spec_from_file_location("vcf_services_ui", APP_PATH)
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)
        self.client = self.module.app.test_client()

    def tearDown(self):
        self.temp.cleanup()

    def write_state(self, **values):
        base = {"running": False, "armed": False, "lastRun": {}}
        base.update(values)
        (self.state_dir / "state.json").write_text(json.dumps(base))

    def fake_bus(self, values=None):
        bus = mock.MagicMock()
        bus.get.side_effect = lambda key: (values or {}).get(key)
        return bus

    def test_dormant_status_has_registration_guidance(self):
        self.write_state()
        response = self.client.get("/api/status")
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertFalse(body["armed"])
        self.assertIn("Register the Software Depot ID", body["armingInstructions"])
        self.assertEqual(body["vcfdtVersion"], "test-version")

    def test_dormant_sync_is_rejected_cleanly(self):
        self.write_state()
        response = self.client.post("/api/sync", json={"targets": ["patches"]})
        self.assertEqual(response.status_code, 409)
        self.assertIn("not armed", response.get_json()["error"])

    def test_invalid_target_is_rejected(self):
        self.write_state(armed=True)
        response = self.client.post("/api/sync", json={"targets": ["invalid"]})
        self.assertEqual(response.status_code, 400)

    def test_sync_publishes_validated_request_to_bus(self):
        self.write_state(armed=True)
        bus = self.fake_bus()
        with mock.patch.object(self.module, "_redis", return_value=bus):
            response = self.client.post(
                "/api/sync", json={"targets": ["patches", "invalid", "esx"]}
            )
        self.assertEqual(response.status_code, 202)
        queue, payload = bus.lpush.call_args.args
        self.assertEqual(queue, "vcf-services:sync:requests")
        request_doc = json.loads(payload)
        self.assertEqual(request_doc["kind"], "sync")
        self.assertEqual(request_doc["targets"], ["patches", "esx"])

    def test_bus_failure_on_sync_returns_502(self):
        self.write_state(armed=True)
        response = self.client.post("/api/sync", json={"targets": ["patches"]})
        self.assertEqual(response.status_code, 502)
        self.assertIn("could not publish", response.get_json()["error"])

    def test_status_prefers_bus_over_state_file(self):
        self.write_state(armed=True, running=False)
        bus_state = {"running": True, "armed": True, "currentTarget": "esx", "lastRun": {}}
        bus = self.fake_bus({"vcf-services:sync:status": json.dumps(bus_state)})
        with mock.patch.object(self.module, "_redis", return_value=bus):
            body = self.client.get("/api/status").get_json()
        self.assertTrue(body["running"])
        self.assertEqual(body["currentTarget"], "esx")

    def test_log_prefers_bus_and_falls_back_to_file(self):
        (self.state_dir / "latest.log").write_text("file line\n")
        bus = self.fake_bus({"vcf-services:sync:log": "bus line"})
        with mock.patch.object(self.module, "_redis", return_value=bus):
            self.assertEqual(self.client.get("/api/log").get_json()["log"], "bus line")
        self.assertEqual(self.client.get("/api/log").get_json()["log"], "file line")

    def test_versions_refresh_publishes_request_and_reports_pending(self):
        bus = self.fake_bus()
        with mock.patch.object(self.module, "_redis", return_value=bus):
            response = self.client.get("/api/versions/remote")
        self.assertEqual(response.status_code, 202)
        self.assertTrue(response.get_json()["pending"])
        queue, payload = bus.lpush.call_args.args
        self.assertEqual(queue, "vcf-services:sync:requests")
        self.assertEqual(json.loads(payload)["kind"], "versions")

    def test_versions_parses_bus_document(self):
        doc = {
            "output": (
                "11111111-1111-4111-8111-111111111111 | SDDC_MANAGER | Stub bundle "
                "| 9.1.0.0.20000000 | 2026-01-01 | 1 KiB | UPGRADE"
            ),
            "fetchedAt": "2026-08-13T00:00:00Z",
            "exitCode": 0,
        }
        bus = self.fake_bus({"vcf-services:sync:versions": json.dumps(doc)})
        with mock.patch.object(self.module, "_redis", return_value=bus):
            body = self.client.get("/api/versions/remote").get_json()
        self.assertEqual(len(body["components"]), 1)
        self.assertEqual(body["components"][0]["build"], "20000000")


if __name__ == "__main__":
    unittest.main()
