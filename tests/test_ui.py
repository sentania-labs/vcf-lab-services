import importlib.util
import io
import json
import os
import tarfile
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock


APP_PATH = Path(__file__).parents[1] / "ui" / "app.py"
BOOTSTRAP_PATH = Path(__file__).parents[1] / "ui" / "bootstrap.py"


class UiApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.state_dir = root / "state"
        self.state_dir.mkdir()
        self.depot = root / "depot"
        self.depot.mkdir()
        self.backup = root / "backup"
        self.backup.mkdir()
        self.settings = root / "settings.env"
        self.settings.write_text(
            'AUTH_USERNAME="vcf"\n'
            'BACKUP_ENABLED="false"\n'
            'CEIP="DISABLE"\n'
            'CRON_SCHEDULE="0 3 * * 0"\n'
            'DEPOT_ENDPOINT="dl.broadcom.com"\n'
            'SETUP_COMPLETE="false"\n'
            'SFTP_UID_GID="1003:1003"\n'
            'SKU="VCF"\n'
            'STORAGE_CONFIRMED="false"\n'
            'SYNC_TARGETS="esx install upgrade patches"\n'
            'TOKEN_URL="https://eapi.broadcom.com/vcf/generateToken"\n'
            'TZ="UTC"\n'
            'VCF_VERSION="9.1.0"\n'
        )
        self.secrets = root / "secrets"
        self.secrets.mkdir()
        self.tool_store = root / "vcfdt-tool"
        environment = {
            "STATE_DIR": str(self.state_dir),
            "SETTINGS_FILE": str(self.settings),
            "DEPOT_DIR": str(self.depot),
            "BACKUP_DIR": str(self.backup),
            "REDIS_HOST": "127.0.0.1",
            "REDIS_PORT": "1",
            "REDIS_PASSWORD_FILE": str(self.secrets / "redis-password"),
            "AUTH_FILE": str(self.secrets / "auth.json"),
            "ACTIVATION_CODE_FILE": str(self.secrets / "activation-code.txt"),
            "SFTP_PASSWORD_FILE": str(self.secrets / "sftp-password"),
            "FLASK_SECRET_FILE": str(self.secrets / "flask-secret"),
            "VCFDT_STORE": str(self.tool_store),
            "SOFTWARE_DEPOT_ID_FILE": str(root / "software-depot-id"),
            "VERSION_MARKER_FILE": str(root / ".vcf-services-version"),
            "VERSION_STATUS_FILE": str(root / ".vcf-services-version-status.json"),
        }
        (self.secrets / "flask-secret").write_text("test-secret\n")
        with mock.patch.dict(os.environ, environment):
            spec = importlib.util.spec_from_file_location("vcf_services_ui", APP_PATH)
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)
        self.client = self.module.app.test_client()

    def tearDown(self):
        self.temp.cleanup()

    def get(self, path, **kwargs):
        return self.client.get(path, base_url="https://localhost", **kwargs)

    def post(self, path, **kwargs):
        return self.client.post(path, base_url="https://localhost", **kwargs)

    def claim(self, password="a strong test password"):
        return self.post(
            "/api/claim", json={"username": "vcf", "password": password}
        )

    def write_state(self, **values):
        base = {"running": False, "armed": False, "lastRun": {}}
        base.update(values)
        (self.state_dir / "state.json").write_text(json.dumps(base))

    def fake_bus(self, values=None):
        bus = mock.MagicMock()
        bus.get.side_effect = lambda key: (values or {}).get(key)
        return bus

    @staticmethod
    def tar_tool(version="9.1.2", machine_id="11111111-1111-4111-8111-111111111111"):
        payload = (
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = configuration ]; then\n"
            f"  echo 'Software Depot ID: {machine_id}'\n"
            "else\n"
            f"  echo 'vcf-download-tool {version}'\n"
            "fi\n"
        ).encode()
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            info = tarfile.TarInfo("vcf-download-tool/bin/vcf-download-tool")
            info.size = len(payload)
            info.mode = 0o755
            archive.addfile(info, io.BytesIO(payload))
            properties = (
                b"lcm.depot.adapter.host=old.example.test\n"
                b"lcm.access_token.broadcom.authorization.server.url=https://old.example.test/token\n"
            )
            info = tarfile.TarInfo(
                "vcf-download-tool/conf/application-prodv2.properties"
            )
            info.size = len(properties)
            archive.addfile(info, io.BytesIO(properties))
        stream.seek(0)
        return stream

    def upload_tool(self):
        return self.post(
            "/api/vcfdt",
            data={"archive": (self.tar_tool(), "vcf-download-tool-9.1.2.tar.gz")},
            content_type="multipart/form-data",
        )

    def valid_settings(self):
        return {
            "backupEnabled": True,
            "ceip": "DISABLE",
            "cronSchedule": "0 2 * * 6",
            "depotEndpoint": "downloads.example.test",
            "esxMode": "download",
            "logRetention": 25,
            "sku": "VCF",
            "storageConfirmed": True,
            "syncTargets": ["patches", "install"],
            "timezone": "America/Chicago",
            "tokenUrl": "https://auth.example.test/token",
            "uidGid": "1004:1005",
            "vcfVersion": "9.1.0",
            "vkrMatch": "9.1.*",
            "vkrOs": "photon",
        }

    def test_first_person_claims_appliance_and_second_claim_is_refused(self):
        response = self.claim()
        self.assertEqual(response.status_code, 201)
        self.assertTrue((self.secrets / "auth.json").is_file())
        self.assertEqual(
            (self.secrets / "sftp-password").read_text(), "a strong test password\n"
        )
        second = self.post(
            "/api/claim", json={"username": "vcf", "password": "another strong password"}
        )
        self.assertEqual(second.status_code, 409)

    def test_first_boot_tls_ask_allows_valid_names_only(self):
        self.assertEqual(self.get("/tls/allow?domain=vcf.example.test").status_code, 204)
        self.assertEqual(self.get("/tls/allow?domain=192.0.2.10").status_code, 204)
        self.assertEqual(self.get("/tls/allow?domain=bad_name").status_code, 403)

    def test_console_api_requires_owner_after_claim(self):
        self.claim()
        self.post("/api/logout")
        self.assertEqual(self.get("/api/status").status_code, 401)
        bad = self.post("/api/login", json={"username": "vcf", "password": "wrong"})
        self.assertEqual(bad.status_code, 401)
        good = self.post(
            "/api/login",
            json={"username": "vcf", "password": "a strong test password"},
        )
        self.assertEqual(good.status_code, 200)

    def test_depot_forward_auth_accepts_basic_credentials(self):
        self.claim()
        good = self.get(
            "/auth/check",
            headers={"Authorization": "Basic dmNmOmEgc3Ryb25nIHRlc3QgcGFzc3dvcmQ="},
        )
        self.assertEqual(good.status_code, 200)
        self.assertEqual(self.get("/auth/check").status_code, 401)

    def test_tool_upload_stages_and_selects_valid_archive(self):
        self.claim()
        self.write_state()
        response = self.upload_tool()
        self.assertEqual(response.status_code, 201)
        current = self.tool_store / "current"
        self.assertTrue(current.is_symlink())
        self.assertEqual(response.get_json()["version"], "vcf-download-tool 9.1.2")
        properties = (current / "conf" / "application-prodv2.properties").read_text()
        self.assertIn("lcm.depot.adapter.host=dl.broadcom.com", properties)

    def test_invalid_replacement_preserves_live_tool(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        original = os.readlink(self.tool_store / "current")
        invalid = io.BytesIO()
        with tarfile.open(fileobj=invalid, mode="w:gz") as archive:
            info = tarfile.TarInfo("README")
            info.size = 3
            archive.addfile(info, io.BytesIO(b"bad"))
        invalid.seek(0)
        response = self.post(
            "/api/vcfdt",
            data={"archive": (invalid, "vcf-download-tool-2.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(os.readlink(self.tool_store / "current"), original)

    def test_implausible_tool_probes_preserve_verified_depot_id(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        self.assertEqual(self.get("/api/registration").get_json()["machineId"], verified_id)
        original = os.readlink(self.tool_store / "current")

        bad_version = self.tar_tool(version="fake", machine_id="fake")
        response = self.post(
            "/api/vcfdt",
            data={"archive": (bad_version, "fake-version.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(os.readlink(self.tool_store / "current"), original)

        bad_id = self.tar_tool(version="9.1.3", machine_id="fake")
        response = self.post(
            "/api/vcfdt",
            data={"archive": (bad_id, "fake-id.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(os.readlink(self.tool_store / "current"), original)
        self.module._machine_id_cache["value"] = None
        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 200)
        self.assertEqual(registration.get_json()["machineId"], verified_id)

    def test_failed_machine_id_probe_reports_error_without_replacing_saved_id(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        self.assertEqual(self.get("/api/registration").get_json()["machineId"], verified_id)
        tool = self.tool_store / "current" / "bin" / "vcf-download-tool"
        tool.write_text("#!/bin/sh\necho fake\n")
        tool.chmod(0o755)
        self.module._machine_id_cache["value"] = None

        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 409)
        body = registration.get_json()
        self.assertEqual(body["machineId"], verified_id)
        self.assertIn("probe failed", body["error"])
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), verified_id
        )

    def test_registration_reads_machine_id_and_saves_activation_secret(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        status = self.get("/api/registration").get_json()
        self.assertEqual(
            status["machineId"], "11111111-1111-4111-8111-111111111111"
        )
        saved = self.post(
            "/api/registration", json={"activationCode": "licensed-secret-value"}
        )
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(
            (self.secrets / "activation-code.txt").read_text(),
            "licensed-secret-value\n",
        )
        self.assertNotIn("licensed-secret-value", saved.get_data(as_text=True))

    def test_settings_replace_installer_questions_and_patch_tool_endpoints(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        response = self.post("/api/settings", json=self.valid_settings())
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(body["cronSchedule"], "0 2 * * 6")
        self.assertTrue(body["storageConfirmed"])
        settings_text = self.settings.read_text()
        self.assertNotIn("NFS_", settings_text)
        self.assertIn('DEPOT_ENDPOINT="downloads.example.test"', settings_text)
        properties = (
            self.tool_store / "current" / "conf" / "application-prodv2.properties"
        ).read_text()
        self.assertIn("lcm.depot.adapter.host=downloads.example.test", properties)

    def test_partial_settings_update_merges_over_stored_document(self):
        self.claim()
        self.write_state()
        response = self.post(
            "/api/settings", json={"cronSchedule": "30 2 * * *"}
        )
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(body["cronSchedule"], "30 2 * * *")
        self.assertEqual(body["vcfVersion"], "9.1.0")
        self.assertEqual(body["sku"], "VCF")

    def test_version_mismatch_reports_blocked_setup_and_refuses_changes(self):
        self.claim()
        self.settings.write_text(
            self.settings.read_text().replace(
                'SETUP_COMPLETE="false"', 'SETUP_COMPLETE="true"'
            )
        )
        status_file = Path(self.module.VERSION_STATUS_FILE)
        status_file.write_text(
            json.dumps(
                {
                    "blocked": True,
                    "expectedVersion": "v0.2.1",
                    "foundVersion": "v0.1.0",
                    "message": "Startup is blocked because v0.1.0 state is not trusted.",
                }
            )
        )
        bootstrap = self.get("/api/bootstrap")
        self.assertEqual(bootstrap.status_code, 200)
        self.assertFalse(bootstrap.get_json()["setupComplete"])
        self.assertTrue(bootstrap.get_json()["versionProblem"]["blocked"])
        refused = self.post(
            "/api/settings", json={"cronSchedule": "30 2 * * *"}
        )
        self.assertEqual(refused.status_code, 409)
        self.assertIn("Startup is blocked", refused.get_json()["error"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        depot_auth = self.get(
            "/auth/check",
            headers={"Authorization": "Basic dmNmOmEgc3Ryb25nIHRlc3QgcGFzc3dvcmQ="},
        )
        self.assertEqual(depot_auth.status_code, 503)

    def test_settings_reject_bad_schedule_and_bad_uid(self):
        self.claim()
        self.write_state()
        body = self.valid_settings()
        body["cronSchedule"] = "bad"
        self.assertEqual(self.post("/api/settings", json=body).status_code, 400)
        body = self.valid_settings()
        body["cronSchedule"] = "0 3 * * $(id)"
        self.assertEqual(self.post("/api/settings", json=body).status_code, 400)
        body = self.valid_settings()
        body["uidGid"] = "0:1003"
        self.assertEqual(self.post("/api/settings", json=body).status_code, 400)

    def test_setup_finishes_only_after_tool_registration_and_storage(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.post("/api/setup/complete").status_code, 409)
        self.upload_tool()
        self.post("/api/registration", json={"activationCode": "secret"})
        self.post("/api/settings", json=self.valid_settings())
        response = self.post("/api/setup/complete")
        self.assertEqual(response.status_code, 200)
        self.assertIn('SETUP_COMPLETE="true"', self.settings.read_text())

    def test_concurrent_settings_writes_do_not_drop_updates(self):
        keys = [f"CONCURRENT_TEST_KEY_{index}" for index in range(8)]
        barrier = threading.Barrier(len(keys))

        def write(key):
            barrier.wait()
            self.module._write_settings({key: f"value-{key}"})

        with ThreadPoolExecutor(max_workers=len(keys)) as executor:
            list(executor.map(write, keys))

        values = self.module._settings()
        for key in keys:
            self.assertEqual(values.get(key), f"value-{key}")

    def test_shared_password_change_updates_console_and_sftp(self):
        self.claim()
        response = self.post(
            "/api/password",
            json={
                "currentPassword": "a strong test password",
                "newPassword": "a different strong password",
            },
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            (self.secrets / "sftp-password").read_text(),
            "a different strong password\n",
        )
        self.post("/api/logout")
        login = self.post(
            "/api/login",
            json={"username": "vcf", "password": "a different strong password"},
        )
        self.assertEqual(login.status_code, 200)

    def test_overlapping_password_changes_leave_one_shared_credential(self):
        self.claim()
        barrier = threading.Barrier(2)

        def change_password(name, new_password):
            client = self.module.app.test_client()
            login = client.post(
                "/api/login",
                base_url="https://localhost",
                json={"username": "vcf", "password": "a strong test password"},
            )
            self.assertEqual(login.status_code, 200)
            barrier.wait()
            response = client.post(
                "/api/password",
                base_url="https://localhost",
                json={
                    "currentPassword": "a strong test password",
                    "newPassword": new_password,
                },
            )
            return name, response.status_code

        changes = {
            "first": "first replacement password",
            "second": "second replacement password",
        }
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [
                executor.submit(change_password, name, password)
                for name, password in changes.items()
            ]
            results = dict(future.result(timeout=10) for future in futures)

        self.assertEqual(sorted(results.values()), [200, 403])
        winner = next(name for name, status in results.items() if status == 200)
        winning_password = changes[winner]
        self.assertEqual(
            (self.secrets / "sftp-password").read_text(), winning_password + "\n"
        )
        self.assertTrue(self.module._verify_credentials("vcf", winning_password))
        losing_password = next(
            password for name, password in changes.items() if name != winner
        )
        self.assertFalse(self.module._verify_credentials("vcf", losing_password))

    def test_password_change_rolls_back_sftp_when_auth_write_fails(self):
        self.claim()
        original_write_secret = self.module._write_secret

        def fail_auth_write(path, value):
            if path == self.module.AUTH_FILE:
                raise OSError("simulated auth write failure")
            return original_write_secret(path, value)

        with mock.patch.object(
            self.module, "_write_secret", side_effect=fail_auth_write
        ):
            response = self.post(
                "/api/password",
                json={
                    "currentPassword": "a strong test password",
                    "newPassword": "a failed replacement password",
                },
            )

        self.assertEqual(response.status_code, 500)
        self.assertEqual(
            (self.secrets / "sftp-password").read_text(),
            "a strong test password\n",
        )
        self.assertTrue(
            self.module._verify_credentials("vcf", "a strong test password")
        )
        self.assertFalse(
            self.module._verify_credentials("vcf", "a failed replacement password")
        )

    def test_sync_uses_activation_secret_and_publishes_valid_targets(self):
        self.claim()
        self.write_state()
        (self.secrets / "activation-code.txt").write_text("secret\n")
        bus = self.fake_bus()
        with mock.patch.object(self.module, "_redis", return_value=bus):
            response = self.post(
                "/api/sync", json={"targets": ["patches", "invalid", "esx"]}
            )
        self.assertEqual(response.status_code, 202)
        payload = json.loads(bus.lpush.call_args.args[1])
        self.assertEqual(payload["targets"], ["patches", "esx"])

    def test_status_uses_configured_timezone_and_activation_file(self):
        self.claim()
        self.settings.write_text(
            self.settings.read_text().replace('TZ="UTC"', 'TZ="Pacific/Kiritimati"')
            .replace('CRON_SCHEDULE="0 3 * * 0"', 'CRON_SCHEDULE="0 3 * * *"')
        )
        self.write_state(armed=False)
        (self.secrets / "activation-code.txt").write_text("secret\n")
        body = self.get("/api/status").get_json()
        next_run = datetime.fromisoformat(body["nextRun"])
        self.assertEqual(next_run.utcoffset(), timedelta(hours=14))
        self.assertTrue(body["armed"])

    def test_versions_parse_bus_document(self):
        self.claim()
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
            body = self.get("/api/versions/remote").get_json()
        self.assertEqual(body["components"][0]["build"], "20000000")


class BootstrapVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        self.secrets = self.root / "secrets"

    def tearDown(self):
        self.temp.cleanup()

    def run_bootstrap(self):
        environment = {
            "CONFIG_DIR": str(self.config),
            "SECRETS_DIR": str(self.secrets),
            "VCF_SERVICES_VERSION": "v0.2.1",
        }
        with mock.patch.dict(os.environ, environment):
            spec = importlib.util.spec_from_file_location(
                f"vcf_services_bootstrap_{id(self)}", BOOTSTRAP_PATH
            )
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            module.main()
        return module

    def test_clean_boot_writes_version_marker(self):
        module = self.run_bootstrap()
        self.assertEqual(module.VERSION_MARKER.read_text().strip(), "v0.2.1")
        self.assertFalse(module.VERSION_STATUS.exists())

    def test_existing_unmarked_config_is_quarantined_without_rewriting_setup(self):
        self.config.mkdir()
        settings = self.config / "settings.env"
        settings.write_text('SETUP_COMPLETE="true"\n')
        module = self.run_bootstrap()
        status = json.loads(module.VERSION_STATUS.read_text())
        self.assertTrue(status["blocked"])
        self.assertIsNone(status["foundVersion"])
        self.assertIn("unversioned state", status["message"])
        self.assertEqual(settings.read_text(), 'SETUP_COMPLETE="true"\n')
        self.assertFalse(module.VERSION_MARKER.exists())

    def test_mismatched_marker_is_quarantined(self):
        self.config.mkdir()
        (self.config / "settings.env").write_text('SETUP_COMPLETE="true"\n')
        (self.config / ".vcf-services-version").write_text("v0.1.0\n")
        module = self.run_bootstrap()
        status = json.loads(module.VERSION_STATUS.read_text())
        self.assertEqual(status["expectedVersion"], "v0.2.1")
        self.assertEqual(status["foundVersion"], "v0.1.0")
        self.assertEqual(
            (self.config / ".vcf-services-version").read_text(), "v0.1.0\n"
        )


if __name__ == "__main__":
    unittest.main()
