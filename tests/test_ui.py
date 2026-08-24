import importlib.util
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta
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
        self.sftp_secrets = root / "sftp-secrets"
        self.sftp_secrets.mkdir()
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
            "SFTP_SECRET_DIR": str(self.sftp_secrets),
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

    def test_versions_surfaces_vendor_failure_exit_code(self):
        doc = {
            "output": "token endpoint rejected the activation code",
            "fetchedAt": "2026-08-13T00:00:00Z",
            "exitCode": 3,
        }
        bus = self.fake_bus({"vcf-services:sync:versions": json.dumps(doc)})
        with mock.patch.object(self.module, "_redis", return_value=bus):
            response = self.client.get("/api/versions/remote")
        self.assertEqual(response.status_code, 502)
        body = response.get_json()
        self.assertIn("exit code 3", body["error"])
        self.assertIn("rejected the activation code", body["error"])
        self.assertEqual(body["components"], [])

    def test_next_run_matches_configured_timezone(self):
        self.settings.write_text(
            'CRON_SCHEDULE="0 3 * * *"\n'
            'TZ="Pacific/Kiritimati"\n'
        )
        self.write_state()
        body = self.client.get("/api/status").get_json()
        next_run = datetime.fromisoformat(body["nextRun"])
        self.assertEqual(next_run.utcoffset(), timedelta(hours=14))
        self.assertEqual((next_run.hour, next_run.minute), (3, 0))

    def test_next_run_falls_back_to_utc_for_bad_timezone(self):
        self.settings.write_text(
            'CRON_SCHEDULE="0 3 * * *"\n'
            'TZ="Not/AZone"\n'
        )
        self.write_state()
        body = self.client.get("/api/status").get_json()
        next_run = datetime.fromisoformat(body["nextRun"])
        self.assertEqual(next_run.utcoffset(), timedelta(0))
        self.assertEqual((next_run.hour, next_run.minute), (3, 0))

    def test_backup_settings_have_safe_defaults_without_exposing_secret(self):
        body = self.client.get("/api/settings/backup").get_json()
        self.assertTrue(body["enabled"])
        self.assertEqual(body["port"], 2222)
        self.assertEqual(body["user"], "vcfbackup")
        self.assertEqual(body["uidGid"], "1003:1003")
        self.assertFalse(body["passwordConfigured"])
        self.assertNotIn("password", body)

    def test_backup_cannot_be_enabled_without_password(self):
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": True,
                "port": 2222,
                "uidGid": "1003:1003",
                "storageMode": "local",
                "localPath": "/srv/vcf-services/depot",
                "backupLocalPath": "/srv/vcf-services/backup",
                "nfsServer": "",
                "nfsExport": "",
                "nfsOptions": "nfsvers=4,rw,hard,timeo=600,retrans=2",
            },
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("password is required", response.get_json()["error"])

    def test_backup_settings_and_password_are_saved_atomically(self):
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": True,
                "port": 2223,
                "uidGid": "1004:1005",
                "password": "a strong test password",
                "storageMode": "nfs",
                "nfsServer": "nfs.example.test",
                "nfsExport": "/exports/vcf-services",
                "backupNfsExport": "/exports/vcf-services-backup",
                "nfsOptions": "nfsvers=4,rw,hard,timeo=600,retrans=2",
            },
        )
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertTrue(body["saved"])
        self.assertTrue(body["installerRerunRequired"])
        self.assertEqual(body["backupPath"], "/exports/vcf-services-backup")
        self.assertTrue(body["passwordConfigured"])
        self.assertEqual(
            (self.sftp_secrets / "password").read_text(), "a strong test password\n"
        )
        settings_text = self.settings.read_text()
        self.assertIn('VCF_VERSION="9.1.0"', settings_text)
        self.assertIn('SFTP_PORT="2223"', settings_text)
        self.assertIn('SFTP_UID_GID="1004:1005"', settings_text)
        self.assertIn(
            'BACKUP_NFS_EXPORT="/exports/vcf-services-backup"', settings_text
        )

    def test_backup_settings_failure_does_not_replace_password(self):
        password_file = self.sftp_secrets / "password"
        password_file.write_text("existing password\n")
        original_settings = self.settings.read_text()
        with mock.patch.object(
            self.module, "_write_settings", side_effect=OSError("read-only config")
        ):
            response = self.client.post(
                "/api/settings/backup",
                json={
                    "enabled": True,
                    "port": 2223,
                    "uidGid": "1004:1005",
                    "password": "replacement password",
                    "storageMode": "local",
                    "localPath": "/srv/vcf-services/depot",
                    "backupLocalPath": "/srv/vcf-services/backup",
                    "nfsServer": "",
                    "nfsExport": "",
                    "nfsOptions": "nfsvers=4,rw",
                },
            )

        self.assertEqual(response.status_code, 500)
        self.assertIn("could not save", response.get_json()["error"])
        self.assertEqual(password_file.read_text(), "existing password\n")
        self.assertEqual(self.settings.read_text(), original_settings)

    def test_backup_settings_validate_uid_gid(self):
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": False,
                "port": 2222,
                "uidGid": "0:1003",
                "storageMode": "local",
                "localPath": "/srv/vcf-services/depot",
                "backupLocalPath": "/srv/vcf-services/backup",
                "nfsServer": "",
                "nfsExport": "",
                "nfsOptions": "nfsvers=4,rw",
            },
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("non-root", response.get_json()["error"])

    def test_backup_port_falls_back_when_setting_is_unparsable(self):
        self.settings.write_text(
            self.settings.read_text() + 'SFTP_PORT=""\n'
        )
        body = self.client.get("/api/settings/backup").get_json()
        self.assertEqual(body["port"], 2222)

    def test_backup_path_inside_the_depot_is_rejected(self):
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": False,
                "port": 2222,
                "uidGid": "1003:1003",
                "storageMode": "local",
                "localPath": "/srv/vcf-services/depot",
                "backupLocalPath": "/srv/vcf-services/depot/backup",
                "nfsServer": "",
                "nfsExport": "",
                "nfsOptions": "nfsvers=4,rw",
            },
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("outside the depot", response.get_json()["error"])

    def test_parent_segment_paths_are_rejected(self):
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": False,
                "port": 2222,
                "uidGid": "1003:1003",
                "storageMode": "nfs",
                "nfsServer": "nfs.example.test",
                "nfsExport": "/exports/vcf-services-depot",
                "backupNfsExport": "/exports/vcf-services-depot/../vcf-services-depot/backup",
                "nfsOptions": "nfsvers=4,rw",
            },
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("..", response.get_json()["error"])

    def test_local_save_falls_back_to_default_nfs_options(self):
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": False,
                "port": 2222,
                "uidGid": "1003:1003",
                "storageMode": "local",
                "localPath": "/srv/vcf-services/depot",
                "backupLocalPath": "/srv/vcf-services/backup",
                "nfsOptions": "",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.get_json()["nfsOptions"], "nfsvers=4,rw,hard,timeo=600,retrans=2"
        )

    def test_switching_to_nfs_preserves_the_local_paths(self):
        self.settings.write_text(
            self.settings.read_text()
            + 'DEPOT_LOCAL_PATH="/srv/vcf-services/depot"\n'
            + 'BACKUP_LOCAL_PATH="/srv/vcf-services/backup"\n'
        )
        response = self.client.post(
            "/api/settings/backup",
            json={
                "enabled": False,
                "port": 2222,
                "uidGid": "1003:1003",
                "storageMode": "nfs",
                "nfsServer": "nfs.example.test",
                "nfsExport": "/exports/vcf-services-depot",
                "backupNfsExport": "/exports/vcf-services-backup",
                "nfsOptions": "nfsvers=4,rw",
            },
        )
        self.assertEqual(response.status_code, 200)
        settings_text = self.settings.read_text()
        self.assertIn('DEPOT_LOCAL_PATH="/srv/vcf-services/depot"', settings_text)
        self.assertIn('BACKUP_LOCAL_PATH="/srv/vcf-services/backup"', settings_text)

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
