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


if __name__ == "__main__":
    unittest.main()
