import fcntl
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from unittest import mock

from jinja2 import FileSystemLoader


APP_PATH = Path(__file__).parents[1] / "ui" / "app.py"
GUNICORN_CONF_PATH = Path(__file__).parents[1] / "ui" / "gunicorn.conf.py"
BOOTSTRAP_PATH = Path(__file__).parents[1] / "ui" / "bootstrap.py"


VOID_TAGS = {"input", "br", "hr", "img", "meta", "link", "source"}
CONTROL_TAGS = {"input", "select", "button", "textarea", "a"}


class ConsoleTabParser(HTMLParser):
    """Collect the tab panels of the console and the controls inside each one."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.panels = []
        self.controls = {}

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        panel = attributes.get("id")
        if panel and panel.startswith("tab-"):
            self.panels.append(panel)
            self.controls.setdefault(panel, [])
        if tag not in VOID_TAGS:
            self.stack.append(panel if panel and panel.startswith("tab-") else None)
        if tag in CONTROL_TAGS and attributes.get("id"):
            current = next(
                (name for name in reversed(self.stack) if name is not None), None
            )
            if current:
                self.controls[current].append(attributes["id"])

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag not in VOID_TAGS and self.stack:
            self.stack.pop()


def parse_console_tabs(markup):
    parser = ConsoleTabParser()
    parser.feed(markup)
    return parser.panels, parser.controls


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
        self.vcfdt_state = root / "vcfdt-state"
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
            "VCFDT_STATE_DIR": str(self.vcfdt_state),
            "SOFTWARE_DEPOT_ID_FILE": str(root / "software-depot-id"),
            "SOFTWARE_DEPOT_ADOPTION_FILE": str(root / ".software-depot-id-adoption.json"),
            "SETTINGS_PENDING_FILE": str(root / ".settings-pending.json"),
            "VERSION_MARKER_FILE": str(root / ".vcf-services-version"),
            "VERSION_STATUS_FILE": str(root / ".vcf-services-version-status.json"),
            "MIGRATION_STATUS_FILE": str(root / ".vcf-services-migration.json"),
            "VCF_SERVICES_VERSION": "v0.2.1",
        }
        (root / ".vcf-services-version").write_text("v0.2.1\n")
        (self.secrets / "flask-secret").write_text("test-secret\n")
        self.environment = environment
        self.module = self.load_app("vcf_services_ui")
        self.client = self.module.app.test_client()

    def load_app(self, name):
        with mock.patch.dict(os.environ, self.environment):
            spec = importlib.util.spec_from_file_location(name, APP_PATH)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        # The module is loaded by path, so Flask resolves its root to the
        # working directory. Point the loader at the real template folder.
        module.app.jinja_loader = FileSystemLoader(str(APP_PATH.parent / "templates"))
        return module

    def new_worker(self, password="a strong test password"):
        """Load the app again over the same files, as a second gunicorn worker
        or a restarted pod would, and sign that worker in."""
        module = self.load_app(f"vcf_services_ui_{uuid.uuid4().hex}")
        client = module.app.test_client()
        signed_in = client.post(
            "/api/login",
            base_url="https://localhost",
            json={"username": "vcf", "password": password},
        )
        self.assertEqual(signed_in.status_code, 200)
        return module, client

    def forbid_tool_launch(self, module=None):
        """Fail the test if anything under this module starts a subprocess."""
        self.launch_guard = mock.patch.object(
            (module or self.module).subprocess,
            "run",
            side_effect=AssertionError("the tool was launched on a read path"),
        )
        self.launch_guard.start()
        self.addCleanup(self.allow_tool_launch)

    def allow_tool_launch(self):
        guard = getattr(self, "launch_guard", None)
        if guard is not None:
            guard.stop()
            self.launch_guard = None

    def current_release_metadata(self):
        return (self.tool_store / "current" / ".vcf-services.json")

    def forget_recorded_probe(self):
        """Strip the recorded probe, as a release written by an older console
        or placed by hand would look."""
        metadata_path = self.current_release_metadata()
        metadata = json.loads(metadata_path.read_text())
        for key in ("machineId", "machineIdProbed", "machineIdProbedAt"):
            metadata.pop(key, None)
        metadata_path.write_text(json.dumps(metadata) + "\n")

    def tearDown(self):
        self.temp.cleanup()

    def get(self, path, **kwargs):
        return self.client.get(path, base_url="https://localhost", **kwargs)

    def post(self, path, **kwargs):
        return self.client.post(path, base_url="https://localhost", **kwargs)

    def delete(self, path, **kwargs):
        return self.client.delete(path, base_url="https://localhost", **kwargs)

    def claim(self, password="a strong test password"):
        return self.post("/api/claim", json={"username": "vcf", "password": password})

    def write_state(self, **values):
        base = {"running": False, "armed": False, "lastRun": {}}
        base.update(values)
        (self.state_dir / "state.json").write_text(json.dumps(base))

    def fake_bus(self, values=None):
        bus = mock.MagicMock()
        bus.get.side_effect = lambda key: (values or {}).get(key)
        return bus

    def seed_content_library(self, name="SUPERVISOR"):
        tree = self.depot / "PROD" / "COMP" / name
        tree.mkdir(parents=True)
        (tree / "lib.json").write_text(json.dumps({"name": name}))
        (tree / "items.json").write_text(
            json.dumps({"items": [{"id": "one"}, {"id": "two"}]})
        )
        (tree / "payload.bin").write_bytes(b"content")
        return tree

    @staticmethod
    def tar_tool(
        version="9.1.2",
        machine_id="11111111-1111-4111-8111-111111111111",
        machine_id_file=None,
        version_output=None,
        profiles=None,
    ):
        if version_output is None:
            version_output = f"Version: {version}\n{version}"
        machine_id_command = (
            f"  cat '{machine_id_file}'\n"
            if machine_id_file is not None
            else f"  echo 'Software Depot ID: {machine_id}'\n"
        )
        payload = (
            "#!/bin/sh\n"
            'if [ "${1:-}" = configuration ]; then\n'
            f"{machine_id_command}"
            "else\n"
            "  cat <<'VCFDT_VERSION_OUTPUT'\n"
            f"{version_output.rstrip()}\n"
            "VCFDT_VERSION_OUTPUT\n"
            "fi\n"
        ).encode()
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            info = tarfile.TarInfo("vcf-download-tool/bin/vcf-download-tool")
            info.size = len(payload)
            info.mode = 0o755
            archive.addfile(info, io.BytesIO(payload))
            if profiles is None:
                profiles = {
                    "application-prod.properties": (
                        "lcm.depot.adapter.host=old.example.test\n"
                        "lcm.access_token.broadcom.authorization.server.url="
                        "https://old.example.test/token\n"
                    ),
                    "application-prodv2.properties": (
                        "lcm.depot.adapter.host=old.example.test\n"
                        "lcm.access_token.broadcom.authorization.server.url="
                        "https://old.example.test/token\n"
                    ),
                }
            for profile, text in profiles.items():
                properties = text.encode()
                info = tarfile.TarInfo(f"vcf-download-tool/conf/{profile}")
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

    def seed_depot_tool(
        self,
        version,
        machine_id="11111111-1111-4111-8111-111111111111",
        subdir=None,
        filename=None,
    ):
        """Place a stub tool archive where the sync mirrors them: PROD/COMP/VCFDT."""
        tree = self.depot / "PROD" / "COMP" / "VCFDT"
        if subdir:
            tree = tree / subdir
        tree.mkdir(parents=True, exist_ok=True)
        target = tree / (filename or f"vcf-download-tool-{version}.tar.gz")
        target.write_bytes(
            self.tar_tool(version=version, machine_id=machine_id).getvalue()
        )
        return target

    def install_from_depot(self, path):
        return self.post("/api/vcfdt/depot", json={"path": path})

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
            "/api/claim",
            json={"username": "vcf", "password": "another strong password"},
        )
        self.assertEqual(second.status_code, 409)

    def test_first_boot_tls_ask_allows_valid_names_only(self):
        self.assertEqual(
            self.get("/tls/allow?domain=vcf.example.test").status_code, 204
        )
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
        self.assertEqual(response.get_json()["version"], "9.1.2")
        self.assertIsNotNone(
            datetime.fromisoformat(response.get_json()["uploadedAt"])
        )
        self.assertNotIn("installedAt", response.get_json())
        metadata = json.loads((current / ".vcf-services.json").read_text())
        self.assertEqual(metadata["uploadedAt"], response.get_json()["uploadedAt"])
        self.assertNotIn("installedAt", metadata)
        status = self.get("/api/status").get_json()
        self.assertEqual(status["vcfdtUploadedAt"], metadata["uploadedAt"])
        self.assertEqual(
            response.get_json()["patchedFiles"],
            [
                "conf/application-prod.properties",
                "conf/application-prodv2.properties",
            ],
        )
        for profile in ("application-prod.properties", "application-prodv2.properties"):
            properties = (current / "conf" / profile).read_text()
            self.assertIn("lcm.depot.adapter.host=dl.broadcom.com", properties)

    def test_tool_upload_patches_prodv2_only_archive(self):
        self.claim()
        self.write_state()
        archive = self.tar_tool(
            profiles={
                "application-prodv2.properties": (
                    "lcm.depot.adapter.host=old.example.test\n"
                    "lcm.access_token.broadcom.authorization.server.url="
                    "https://old.example.test/token\n"
                )
            }
        )
        response = self.post(
            "/api/vcfdt",
            data={"archive": (archive, "vcf-download-tool-prodv2-only.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(
            response.get_json()["patchedFiles"],
            ["conf/application-prodv2.properties"],
        )
        properties = (
            self.tool_store / "current" / "conf" / "application-prodv2.properties"
        ).read_text()
        self.assertIn("lcm.depot.adapter.host=dl.broadcom.com", properties)

    def test_tool_upload_rejects_archive_without_endpoint_keys(self):
        self.claim()
        self.write_state()
        archive = self.tar_tool(
            profiles={
                "application-prod.properties": "unrelated.setting=true\n",
                "application-lab.properties": "lcm.depot.adapter.host=lab.example.test\n",
            }
        )
        response = self.post(
            "/api/vcfdt",
            data={"archive": (archive, "vcf-download-tool-no-endpoints.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("no VCF Download Tool endpoint keys", response.get_json()["error"])
        self.assertFalse((self.tool_store / "current").exists())

    def test_real_tool_version_output_is_parsed(self):
        self.claim()
        self.write_state()
        real_output = """*********Welcome to VCF Download Tool***********

Version: 9.1.0.0.25371089
9.1.0.0.25371089

Log file: /opt/vmware/vcfdt/log/vdt.log
"""
        archive = self.tar_tool(version_output=real_output)
        response = self.post(
            "/api/vcfdt",
            data={"archive": (archive, "vcf-download-tool-real.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.get_json()["version"], "9.1.0.0.25371089")
        self.assertTrue(response.get_json()["versionVerified"])

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
        self.assertEqual(
            self.get("/api/registration").get_json()["machineId"], verified_id
        )
        original = os.readlink(self.tool_store / "current")

        bogus = self.tar_tool(version="fake", machine_id="fake")
        response = self.post(
            "/api/vcfdt",
            data={"archive": (bogus, "bogus-probes.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        body = response.get_json()
        self.assertEqual(body["version"], "unverified")
        self.assertFalse(body["versionVerified"])
        self.assertNotEqual(os.readlink(self.tool_store / "current"), original)
        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 409)
        self.assertEqual(registration.get_json()["machineId"], verified_id)
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), verified_id
        )

    def test_unexpected_version_output_installs_marked_unverified(self):
        self.claim()
        self.write_state()
        new_id = "22222222-2222-4222-8222-222222222222"
        weird = self.tar_tool(version="fake", machine_id=new_id)
        response = self.post(
            "/api/vcfdt",
            data={"archive": (weird, "weird-version.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        body = response.get_json()
        self.assertEqual(body["version"], "unverified")
        self.assertFalse(body["versionVerified"])
        status = self.get("/api/status").get_json()
        self.assertEqual(status["vcfdtVersion"], "unverified")
        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 200)
        self.assertEqual(registration.get_json()["machineId"], new_id)

    def test_failed_machine_id_probe_reports_error_without_replacing_saved_id(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        self.assertEqual(
            self.get("/api/registration").get_json()["machineId"], verified_id
        )
        bogus = self.tar_tool(machine_id="fake")
        response = self.post(
            "/api/vcfdt",
            data={"archive": (bogus, "vcf-download-tool-9.1.3.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(
            response.get_json()["registration"]["machineIdStatus"], "failed"
        )

        # The failure is served from the recorded install outcome, so the
        # read paths report it without launching the tool again.
        self.forbid_tool_launch()
        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 409)
        body = registration.get_json()
        self.assertEqual(body["machineId"], verified_id)
        self.assertEqual(body["machineIdStatus"], "failed")
        self.assertIn("probe failed", body["error"])
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), verified_id
        )
        bootstrap = self.get("/api/bootstrap").get_json()
        self.assertEqual(bootstrap["machineIdStatus"], "failed")
        self.assertEqual(bootstrap["machineId"], verified_id)
        self.assertIn("probe failed", bootstrap["machineIdError"])
        refused = self.post("/api/registration", json={"activationCode": "code"})
        self.assertEqual(refused.status_code, 409)
        self.assertIn("probe failed", refused.get_json()["error"])

        # Verify is the explicit recovery: a corrected tool confirms the ID
        # and the record outlives the request.
        new_id = "22222222-2222-4222-8222-222222222222"
        tool = self.tool_store / "current" / "bin" / "vcf-download-tool"
        tool.write_text(f"#!/bin/sh\necho 'Software Depot ID: {new_id}'\n")
        tool.chmod(0o755)
        self.allow_tool_launch()
        verified = self.post("/api/registration/verify")
        self.assertEqual(verified.status_code, 200)
        self.assertEqual(verified.get_json()["machineId"], new_id)
        self.assertEqual(verified.get_json()["machineIdStatus"], "confirmed")
        self.assertTrue(verified.get_json()["verified"])
        metadata = json.loads(self.current_release_metadata().read_text())
        self.assertEqual(metadata["machineId"], new_id)
        self.assertTrue(metadata["machineIdProbed"])
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), new_id
        )
        confirmed = self.get("/api/registration")
        self.assertEqual(confirmed.status_code, 200)
        self.assertEqual(confirmed.get_json()["machineId"], new_id)

    def test_sign_in_and_bootstrap_never_launch_the_tool(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        # A tool that is slow to start and then fails, as a cold JVM whose
        # probe cannot answer would be. The read paths must not notice.
        tool = self.tool_store / "current" / "bin" / "vcf-download-tool"
        tool.write_text("#!/bin/sh\nsleep 5\nexit 1\n")
        tool.chmod(0o755)
        self.assertEqual(self.post("/api/logout").status_code, 200)

        started = time.monotonic()
        signed_in = self.post(
            "/api/login", json={"username": "vcf", "password": "a strong test password"}
        )
        self.assertEqual(signed_in.status_code, 200)
        bootstrap = self.get("/api/bootstrap")
        elapsed = time.monotonic() - started
        self.assertEqual(bootstrap.status_code, 200)
        body = bootstrap.get_json()
        self.assertTrue(body["authenticated"])
        self.assertEqual(body["machineId"], verified_id)
        self.assertEqual(body["machineIdStatus"], "confirmed")
        self.assertIsNone(body["machineIdError"])
        self.assertIsNotNone(body["machineIdVerifiedAt"])
        self.assertLess(elapsed, 2.0, f"sign-in plus bootstrap took {elapsed:.2f}s")

        self.forbid_tool_launch()
        for _ in range(3):
            self.assertEqual(
                self.get("/api/bootstrap").get_json()["machineId"], verified_id
            )
            self.assertEqual(self.get("/api/registration").status_code, 200)
        self.assertEqual(
            self.post("/api/registration", json={"activationCode": "code"}).status_code,
            200,
        )

    def test_second_worker_and_restart_read_the_recorded_identity(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        tool = self.tool_store / "current" / "bin" / "vcf-download-tool"
        tool.write_text("#!/bin/sh\nsleep 5\nexit 1\n")
        tool.chmod(0o755)

        worker, client = self.new_worker()
        self.forbid_tool_launch(worker)
        bootstrap = client.get("/api/bootstrap", base_url="https://localhost")
        self.assertEqual(bootstrap.status_code, 200)
        self.assertEqual(bootstrap.get_json()["machineId"], verified_id)
        self.assertEqual(bootstrap.get_json()["machineIdStatus"], "confirmed")
        registration = client.get("/api/registration", base_url="https://localhost")
        self.assertEqual(registration.status_code, 200)

    def test_release_without_a_recorded_probe_is_unverified_until_verified(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        self.forget_recorded_probe()

        self.forbid_tool_launch()
        bootstrap = self.get("/api/bootstrap").get_json()
        self.assertEqual(bootstrap["machineIdStatus"], "unverified")
        self.assertEqual(bootstrap["machineId"], verified_id)
        self.assertIsNone(bootstrap["machineIdError"])
        self.assertIn("has not been verified", bootstrap["machineIdMessage"])
        self.assertIn("runs on its own", bootstrap["machineIdMessage"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        refused = self.post("/api/registration", json={"activationCode": "code"})
        self.assertEqual(refused.status_code, 409)
        self.assertIn("Verify with the tool", refused.get_json()["error"])
        self.assertFalse((self.secrets / "activation-code.txt").exists())
        self.post("/api/settings", json=self.valid_settings())
        incomplete = self.post("/api/setup/complete")
        self.assertEqual(incomplete.status_code, 409)
        self.assertIn("Software Depot ID", incomplete.get_json()["error"])

        Path(self.module.SOFTWARE_DEPOT_ID_FILE).unlink()
        unknown = self.get("/api/bootstrap").get_json()
        self.assertEqual(unknown["machineIdStatus"], "unverified")
        self.assertIsNone(unknown["machineId"])
        self.assertIn("has not been read yet", unknown["machineIdMessage"])

        self.allow_tool_launch()
        verified = self.post("/api/registration/verify")
        self.assertEqual(verified.status_code, 200)
        self.assertEqual(verified.get_json()["machineId"], verified_id)
        self.assertEqual(verified.get_json()["machineIdStatus"], "confirmed")
        confirmed = self.get("/api/bootstrap").get_json()
        self.assertEqual(confirmed["machineIdStatus"], "confirmed")
        self.assertEqual(confirmed["machineId"], verified_id)
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), verified_id
        )
        saved = self.post("/api/registration", json={"activationCode": "code"})
        self.assertEqual(saved.status_code, 200)

    def test_verify_confirms_a_pending_adoption_and_reports_a_mismatch(self):
        self.claim()
        self.write_state()
        adopted_id = "22222222-2222-4222-8222-222222222222"
        self.assertEqual(
            self.post("/api/registration/adopt", json={"machineId": adopted_id}).status_code,
            200,
        )
        installed = self.post(
            "/api/vcfdt",
            data={
                "archive": (
                    self.tar_tool(machine_id_file=self.vcfdt_state / "machine_id"),
                    "vcf-download-tool-9.1.2.tar.gz",
                )
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(installed.status_code, 201)
        # An adoption record left pending with a tool present, as an
        # out-of-band install would leave it, is reported as pending and is
        # not confirmed by a read.
        self.module._record_machine_id_adoption(adopted_id, "adopted")
        self.forbid_tool_launch()
        pending = self.get("/api/bootstrap").get_json()
        self.assertEqual(pending["machineIdStatus"], "adopted")
        self.assertEqual(pending["machineId"], adopted_id)
        self.assertIn("Verify with the installed tool", pending["machineIdMessage"])
        self.assertEqual(self.get("/api/registration").status_code, 409)

        self.allow_tool_launch()
        verified = self.post("/api/registration/verify")
        self.assertEqual(verified.status_code, 200)
        self.assertEqual(verified.get_json()["machineIdStatus"], "confirmed")
        self.assertEqual(self.module._machine_id_adoption()["status"], "confirmed")

        other_id = "33333333-3333-4333-8333-333333333333"
        (self.vcfdt_state / "machine_id").write_text(other_id)
        mismatch = self.post("/api/registration/verify")
        self.assertEqual(mismatch.status_code, 409)
        self.assertEqual(mismatch.get_json()["machineIdStatus"], "mismatch")
        self.assertIn(other_id, mismatch.get_json()["error"])
        self.assertEqual(self.get("/api/bootstrap").get_json()["machineIdStatus"], "mismatch")

    def run_startup_verification(self, module=None, sleep=lambda _seconds: None, started_at=None):
        module = module or self.module
        return module._startup_identity_verification(
            started_at or datetime.now(timezone.utc).isoformat(),
            delays=(0,), retry_every=0, sleep=sleep,
        )

    def test_startup_verification_confirms_a_legacy_release_without_operator_action(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        # An appliance upgraded from a console that recorded no probe, whose
        # own saved copy of the ID never existed either.
        self.forget_recorded_probe()
        Path(self.module.SOFTWARE_DEPOT_ID_FILE).unlink()
        self.forbid_tool_launch()
        pending = self.get("/api/bootstrap").get_json()
        self.assertEqual(pending["machineIdStatus"], "unverified")
        self.assertIsNone(pending["machineId"])

        # A second worker, as gunicorn boots it, runs the startup hook.
        worker, client = self.new_worker()
        self.allow_tool_launch()
        self.assertEqual(self.run_startup_verification(worker), "verified")
        metadata = json.loads(self.current_release_metadata().read_text())
        self.assertEqual(metadata["machineId"], verified_id)
        self.assertTrue(metadata["machineIdProbed"])
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), verified_id
        )
        # Both workers now serve the confirmed identity from the record, and
        # a repeat of the hook has nothing to do.
        confirmed = self.get("/api/bootstrap").get_json()
        self.assertEqual(confirmed["machineIdStatus"], "confirmed")
        self.assertEqual(confirmed["machineId"], verified_id)
        self.assertEqual(self.get("/api/registration").status_code, 200)
        self.forbid_tool_launch(worker)
        self.assertEqual(self.run_startup_verification(worker), "not needed")
        other = client.get("/api/bootstrap", base_url="https://localhost").get_json()
        self.assertEqual(other["machineIdStatus"], "confirmed")

    def test_startup_verification_defers_for_a_running_sync_or_tool_update(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        self.forget_recorded_probe()
        self.write_state(running=True)
        self.forbid_tool_launch()
        # A sync that outlasts the initial delays: the job keeps waiting at
        # the retry interval, never launches the tool beside it, and verifies
        # once the sync ends.
        slept = []

        def sync_ends_after_six_waits(seconds):
            slept.append(seconds)
            if len(slept) == 6:
                self.assertEqual(
                    self.get("/api/bootstrap").get_json()["machineIdStatus"], "unverified"
                )
                self.write_state()
                self.allow_tool_launch()

        verification = self.module._startup_identity_verification(
            datetime.now(timezone.utc).isoformat(),
            delays=(10, 60, 300, 900), retry_every=900, sleep=sync_ends_after_six_waits,
        )
        self.assertEqual(verification, "verified")
        self.assertEqual(slept, [10, 60, 300, 900, 900, 900])
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "confirmed"
        )

        # A tool update holding the lock defers it the same way.
        self.forget_recorded_probe()
        self.forbid_tool_launch()
        lock = (self.tool_store / ".update.lock").open("a+")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        waits = []

        def update_ends_after_three_waits(seconds):
            waits.append(seconds)
            if len(waits) == 3:
                lock.close()
                self.allow_tool_launch()

        self.assertEqual(
            self.run_startup_verification(sleep=update_ends_after_three_waits), "verified"
        )
        self.assertEqual(len(waits), 3)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "confirmed"
        )

    def test_identity_changed_after_verification_is_reverified_at_start(self):
        self.claim()
        self.write_state()
        first_id = "11111111-1111-4111-8111-111111111111"
        changed_id = "44444444-4444-4444-8444-444444444444"
        self.vcfdt_state.mkdir()
        (self.vcfdt_state / "machine_id").write_text(first_id + "\n")
        installed = self.post(
            "/api/vcfdt",
            data={
                "archive": (
                    self.tar_tool(machine_id_file=self.vcfdt_state / "machine_id"),
                    "vcf-download-tool-9.1.2.tar.gz",
                )
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(installed.status_code, 201)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "confirmed"
        )

        # The identity file is replaced outside the console after the probe.
        # The record is backdated so the comparison does not depend on how
        # quickly this test runs.
        metadata_path = self.current_release_metadata()
        metadata = json.loads(metadata_path.read_text())
        metadata["machineIdProbedAt"] = (
            datetime.now(timezone.utc) - timedelta(seconds=10)
        ).isoformat()
        metadata_path.write_text(json.dumps(metadata) + "\n")
        identity = self.vcfdt_state / "machine_id"
        identity.write_text(changed_id + "\n")
        self.forbid_tool_launch()
        stale = self.get("/api/bootstrap").get_json()
        self.assertEqual(stale["machineIdStatus"], "unverified")
        self.assertEqual(stale["machineId"], first_id)
        self.assertIn("changed afterwards", stale["machineIdMessage"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        refused = self.post("/api/registration", json={"activationCode": "code"})
        self.assertEqual(refused.status_code, 409)

        self.allow_tool_launch()
        self.assertEqual(self.run_startup_verification(), "verified")
        self.forbid_tool_launch()
        reverified = self.get("/api/bootstrap").get_json()
        self.assertEqual(reverified["machineIdStatus"], "confirmed")
        self.assertEqual(reverified["machineId"], changed_id)
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), changed_id
        )

    def backdate_recorded_probe(self):
        metadata_path = self.current_release_metadata()
        metadata = json.loads(metadata_path.read_text())
        metadata["machineIdProbedAt"] = (
            datetime.now(timezone.utc) - timedelta(seconds=10)
        ).isoformat()
        metadata_path.write_text(json.dumps(metadata) + "\n")
        return metadata["machineIdProbedAt"]

    def test_identity_changed_after_a_confirmed_adoption_is_not_reported_confirmed(self):
        self.claim()
        self.write_state()
        adopted_id = "22222222-2222-4222-8222-222222222222"
        changed_id = "44444444-4444-4444-8444-444444444444"
        self.assertEqual(
            self.post("/api/registration/adopt", json={"machineId": adopted_id}).status_code,
            200,
        )
        identity = self.vcfdt_state / "machine_id"
        installed = self.post(
            "/api/vcfdt",
            data={
                "archive": (
                    self.tar_tool(machine_id_file=identity),
                    "vcf-download-tool-9.1.2.tar.gz",
                )
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(installed.status_code, 201)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "confirmed"
        )

        probed_at = self.backdate_recorded_probe()
        identity.write_text(changed_id + "\n")
        self.forbid_tool_launch()
        stale = self.get("/api/bootstrap").get_json()
        self.assertEqual(stale["machineIdStatus"], "unverified")
        self.assertEqual(stale["machineId"], adopted_id)
        self.assertEqual(stale["machineIdVerifiedAt"], probed_at)
        self.assertIn("changed afterwards", stale["machineIdMessage"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        refused = self.post("/api/registration", json={"activationCode": "code"})
        self.assertEqual(refused.status_code, 409)
        self.assertFalse((self.secrets / "activation-code.txt").exists())

        self.allow_tool_launch()
        self.assertEqual(self.run_startup_verification(), "verified")
        mismatch = self.get("/api/bootstrap").get_json()
        self.assertEqual(mismatch["machineIdStatus"], "mismatch")
        self.assertEqual(mismatch["reportedMachineId"], changed_id)

        self.backdate_recorded_probe()
        identity.write_text(adopted_id + "\n")
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "unverified"
        )
        self.assertEqual(self.run_startup_verification(), "verified")
        confirmed = self.get("/api/bootstrap").get_json()
        self.assertEqual(confirmed["machineIdStatus"], "confirmed")
        self.assertEqual(confirmed["machineId"], adopted_id)
        self.assertEqual(self.get("/api/registration").status_code, 200)

    def test_identity_changed_after_a_mismatch_never_claims_the_adopted_id_verified(self):
        self.claim()
        self.write_state()
        adopted_id = "22222222-2222-4222-8222-222222222222"
        reported_id = "11111111-1111-4111-8111-111111111111"
        self.assertEqual(
            self.post("/api/registration/adopt", json={"machineId": adopted_id}).status_code,
            200,
        )
        self.assertEqual(self.upload_tool().status_code, 201)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "mismatch"
        )

        self.backdate_recorded_probe()
        (self.vcfdt_state / "machine_id").write_text(reported_id + "\n")
        self.forbid_tool_launch()
        stale = self.get("/api/bootstrap").get_json()
        self.assertEqual(stale["machineIdStatus"], "unverified")
        self.assertIn(adopted_id, stale["machineIdMessage"])
        self.assertIn(reported_id, stale["machineIdMessage"])
        self.assertIn("changed afterwards", stale["machineIdMessage"])
        self.assertNotIn("was verified", stale["machineIdMessage"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        refused = self.post("/api/registration", json={"activationCode": "code"})
        self.assertEqual(refused.status_code, 409)
        self.assertFalse((self.secrets / "activation-code.txt").exists())

    def test_workers_share_one_start_time_verification_of_a_failed_probe(self):
        self.claim()
        self.write_state()
        response = self.post(
            "/api/vcfdt",
            data={"archive": (self.tar_tool(machine_id="fake"), "vcf-download-tool-9.1.3.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "failed"
        )
        # The failed record predates this start, so it is retried once.
        started_at = datetime.now(timezone.utc).isoformat()
        first, _ = self.new_worker()
        second, _ = self.new_worker()
        launches = []
        real_run = first.subprocess.run

        def counted_run(*args, **kwargs):
            launches.append(args)
            return real_run(*args, **kwargs)

        with mock.patch.object(first.subprocess, "run", side_effect=counted_run):
            self.assertEqual(
                self.run_startup_verification(first, started_at=started_at), "failed"
            )
        self.assertTrue(launches)
        launched = len(launches)

        self.forbid_tool_launch(second)
        self.assertEqual(
            self.run_startup_verification(second, started_at=started_at), "not needed"
        )
        self.assertEqual(
            self.run_startup_verification(first, started_at=started_at), "not needed"
        )
        self.assertEqual(len(launches), launched)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "failed"
        )

    @unittest.skipIf(os.geteuid() == 0, "root reads files regardless of their mode")
    def test_unreadable_release_metadata_is_not_replaced_by_verification(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        metadata_path = self.current_release_metadata()
        original = metadata_path.read_bytes()
        metadata_path.chmod(0o000)
        try:
            verified = self.post("/api/registration/verify")
        finally:
            metadata_path.chmod(0o644)
        self.assertEqual(verified.status_code, 500)
        self.assertEqual(metadata_path.read_bytes(), original)

    def run_console(self, payload):
        result = subprocess.run(
            ["node", str(APP_PATH.parents[1] / "tests" / "console-status.cjs")],
            input=json.dumps({"html": self.get("/").get_data(as_text=True), **payload}),
            text=True, capture_output=True, check=True,
        )
        return json.loads(result.stdout)

    @unittest.skipUnless(shutil.which("node"), "Node is required to execute console JavaScript")
    def test_console_identity_refresh_backs_off_and_stops_when_signed_out(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        confirmed = self.get("/api/bootstrap").get_json()
        status = self.get("/api/status").get_json()
        self.forget_recorded_probe()
        pending = self.get("/api/bootstrap").get_json()
        self.assertEqual(pending["machineIdStatus"], "unverified")
        still_pending = {"api/bootstrap": {"status": 200, "body": pending}}

        signed_out = self.run_console({
            "status": status,
            "identity": pending,
            "polls": [
                {"at": 5000, "responses": {
                    "api/bootstrap": {"status": 200, "body": {"claimed": True, "authenticated": False}},
                    "api/status": {"status": 401, "body": {"error": "sign in to continue"}},
                }},
                {"at": 10000, "responses": {
                    "api/status": {"status": 401, "body": {"error": "sign in to continue"}},
                }},
            ],
        })
        self.assertEqual([step["bootstrapCalls"] for step in signed_out], [1, 1])
        self.assertEqual([step["statusCalls"] for step in signed_out], [1, 2])
        self.assertEqual(signed_out[-1]["error"], "sign in to continue")

        seconds = [5, 30, 55, 65, 90, 120, 125, 180, 185]
        backoff = self.run_console({
            "status": status,
            "identity": pending,
            "polls": [{"at": at * 1000, "responses": still_pending} for at in seconds]
            + [{"at": 245000, "responses": {"api/bootstrap": {"status": 200, "body": confirmed}}},
               {"at": 250000, "responses": still_pending},
               {"at": 400000, "responses": still_pending}],
        })
        self.assertEqual(
            [step["bootstrapCalls"] for step in backoff],
            [1, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6, 6],
        )
        self.assertEqual([step["statusCalls"] for step in backoff], list(range(1, 13)))
        self.assertIn("Confirmed by the installed tool", backoff[-1]["machineIdStatus"])

    @unittest.skipUnless(shutil.which("node"), "Node is required to execute console JavaScript")
    def test_console_sign_in_shows_progress_while_the_credential_is_checked(self):
        rendered = self.run_console({
            "login": {"status": 401, "body": {"error": "the username or password is incorrect"}},
        })
        self.assertEqual(
            rendered["pending"],
            {"disabled": True, "label": "Signing in", "flash": "Checking the credential"},
        )
        self.assertEqual(
            rendered["finished"],
            {"disabled": False, "label": "Sign in", "flash": "the username or password is incorrect"},
        )

    def test_startup_verification_retries_a_failed_probe_and_pending_adoption(self):
        self.claim()
        self.write_state()
        bogus = self.tar_tool(machine_id="fake")
        response = self.post(
            "/api/vcfdt",
            data={"archive": (bogus, "vcf-download-tool-9.1.3.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "failed"
        )
        # The probe fails again at start: recorded as failed, no ID invented.
        self.assertEqual(self.run_startup_verification(), "failed")
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "failed"
        )
        new_id = "22222222-2222-4222-8222-222222222222"
        tool = self.tool_store / "current" / "bin" / "vcf-download-tool"
        tool.write_text(f"#!/bin/sh\necho 'Software Depot ID: {new_id}'\n")
        tool.chmod(0o755)
        self.assertEqual(self.run_startup_verification(), "verified")
        self.assertEqual(self.get("/api/bootstrap").get_json()["machineId"], new_id)

        # An adoption left pending with a tool present is confirmed at start.
        self.module._record_machine_id_adoption(new_id, "adopted")
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "adopted"
        )
        self.assertEqual(self.run_startup_verification(), "verified")
        self.assertEqual(self.module._machine_id_adoption()["status"], "confirmed")
        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineIdStatus"], "confirmed"
        )

    def test_startup_verification_is_skipped_without_a_tool_and_when_recorded(self):
        self.claim()
        self.write_state()
        self.forbid_tool_launch()
        self.assertEqual(self.run_startup_verification(), "not needed")
        self.allow_tool_launch()
        self.assertEqual(self.upload_tool().status_code, 201)
        self.forbid_tool_launch()
        self.assertEqual(self.run_startup_verification(), "not needed")

    def test_gunicorn_worker_hook_starts_the_background_verification(self):
        spec = importlib.util.spec_from_file_location("gunicorn_conf", GUNICORN_CONF_PATH)
        hooks = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hooks)
        outcomes = []
        with mock.patch.dict(os.environ), mock.patch.dict(
            sys.modules, {"app": self.module}
        ), mock.patch.object(
            self.module,
            "_startup_identity_verification",
            side_effect=lambda started_at: outcomes.append(started_at),
        ):
            os.environ.pop("VCF_UI_STARTED_AT", None)
            before = datetime.now(timezone.utc)
            hooks.on_starting(mock.Mock())
            started_at = os.environ["VCF_UI_STARTED_AT"]
            self.assertGreaterEqual(datetime.fromisoformat(started_at), before)
            start_verification = self.module.verify_identity_on_start
            threads = []
            with mock.patch.object(
                self.module,
                "verify_identity_on_start",
                side_effect=lambda: threads.append(start_verification()),
            ) as start:
                hooks.post_worker_init(mock.Mock())
            start.assert_called_once_with()
            threads[0].join(timeout=5)
            self.assertTrue(threads[0].daemon)
            os.environ.pop("VCF_UI_STARTED_AT")
            self.module.verify_identity_on_start().join(timeout=5)
        self.assertEqual(outcomes[0], started_at)
        self.assertGreater(datetime.fromisoformat(outcomes[1]), datetime.fromisoformat(started_at))

    def test_verify_is_refused_without_a_tool_during_sync_or_tool_update(self):
        self.claim()
        self.write_state()
        missing = self.post("/api/registration/verify")
        self.assertEqual(missing.status_code, 409)
        self.assertIn("install the VCF Download Tool", missing.get_json()["error"])

        self.assertEqual(self.upload_tool().status_code, 201)
        self.write_state(running=True)
        self.forbid_tool_launch()
        busy = self.post("/api/registration/verify")
        self.assertEqual(busy.status_code, 409)
        self.assertIn("running sync", busy.get_json()["error"])

        self.write_state()
        lock = (self.tool_store / ".update.lock").open("a+")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locked = self.post("/api/registration/verify")
        self.assertEqual(locked.status_code, 409)
        self.assertIn("tool update", locked.get_json()["error"])

    def test_depot_listing_finds_tool_archives_under_vcfdt(self):
        self.claim()
        self.write_state()
        empty = self.get("/api/vcfdt/depot")
        self.assertEqual(empty.status_code, 200)
        self.assertFalse(empty.get_json()["mounted"])
        self.assertEqual(empty.get_json()["archives"], [])

        old = self.seed_depot_tool("9.1.0.0.25371089")
        new = self.seed_depot_tool("9.1.0.0100.25429019")
        self.seed_depot_tool("9.1.0.0400.25570101", subdir="9.1.0.0400.25570101")
        (self.depot / "PROD" / "COMP" / "VCFDT" / "metadata.json").write_text("{}")
        outside = self.depot / "PROD" / "COMP" / "ESX_HOST"
        outside.mkdir(parents=True)
        (outside / "vcf-download-tool-9.9.9.tar.gz").write_bytes(
            self.tar_tool().getvalue()
        )
        (
            self.depot / "PROD" / "COMP" / "VCFDT" / "vcf-download-tool-9.9.9.tar.gz"
        ).symlink_to(outside / "vcf-download-tool-9.9.9.tar.gz")

        unnamed = self.seed_depot_tool("9.1.2", filename="vcf-download-tool.zip")

        listing = self.get("/api/vcfdt/depot").get_json()
        self.assertTrue(listing["mounted"])
        self.assertEqual(
            [entry["version"] for entry in listing["archives"]],
            ["9.1.0.0100.25429019", "9.1.0.0.25371089", "unknown"],
        )
        self.assertEqual(
            [entry["path"] for entry in listing["archives"]],
            [new.name, old.name, unnamed.name],
        )
        for entry, source in zip(listing["archives"], (new, old)):
            self.assertEqual(entry["filename"], source.name)
            self.assertEqual(entry["sizeBytes"], source.stat().st_size)
            self.assertTrue(entry["versionKnown"])
            self.assertTrue(entry["readable"])
            self.assertIsNotNone(datetime.fromisoformat(entry["modifiedAt"]))
            self.assertFalse(entry["installed"])
        self.assertFalse(listing["archives"][-1]["versionKnown"])
        self.assertFalse(listing["installed"]["installed"])

        self.assertEqual(self.install_from_depot(new.name).status_code, 201)
        listing = self.get("/api/vcfdt/depot").get_json()
        self.assertEqual(
            [entry["installed"] for entry in listing["archives"]],
            [True, False, False],
        )
        self.assertEqual(listing["installed"]["version"], "9.1.0.0100.25429019")
        self.assertEqual(listing["installed"]["source"], "depot")

    @unittest.skipIf(os.geteuid() == 0, "root reads every file regardless of mode")
    def test_depot_listing_flags_unreadable_archives(self):
        self.claim()
        self.write_state()
        readable = self.seed_depot_tool("9.1.0.0100.25429019")
        locked = self.seed_depot_tool("9.1.0.0.25371089")
        locked.chmod(0o000)
        self.addCleanup(lambda: locked.exists() and locked.chmod(0o644))
        listing = self.get("/api/vcfdt/depot").get_json()
        self.assertEqual(
            [(entry["path"], entry["readable"]) for entry in listing["archives"]],
            [(readable.name, True), (locked.name, False)],
        )
        response = self.install_from_depot(locked.name)
        self.assertEqual(response.status_code, 400)
        self.assertIn("file mode", response.get_json()["error"])

    def test_install_from_depot_swaps_release_and_preserves_depot_id(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        verified_id = "11111111-1111-4111-8111-111111111111"
        self.assertEqual(
            self.get("/api/registration").get_json()["machineId"], verified_id
        )
        original = os.readlink(self.tool_store / "current")
        original_release = (self.tool_store / original).resolve()
        archive = self.seed_depot_tool("9.1.0.0400.25570101", machine_id=verified_id)
        before = archive.read_bytes()
        depot_tree = archive.parent
        tree_before = sorted(path.name for path in depot_tree.iterdir())
        # The console mounts the depot read-only; prove the install never needs
        # to write there by taking write access away from the whole tree.
        locked = [
            self.depot,
            self.depot / "PROD",
            self.depot / "PROD" / "COMP",
            depot_tree,
        ]
        for directory in locked:
            directory.chmod(0o555)
        self.addCleanup(
            lambda: [
                directory.chmod(0o755) for directory in locked if directory.exists()
            ]
        )

        response = self.install_from_depot(archive.name)
        self.assertEqual(response.status_code, 201)
        body = response.get_json()
        self.assertEqual(body["version"], "9.1.0.0400.25570101")
        self.assertTrue(body["versionVerified"])
        self.assertEqual(body["source"], "depot")
        self.assertEqual(body["sourceFile"], archive.name)
        self.assertEqual(
            body["patchedFiles"],
            [
                "conf/application-prod.properties",
                "conf/application-prodv2.properties",
            ],
        )
        current = self.tool_store / "current"
        self.assertTrue(current.is_symlink())
        self.assertNotEqual(os.readlink(current), original)
        self.assertTrue((current / "bin" / "vcf-download-tool").is_file())
        self.assertTrue(original_release.exists())
        self.assertEqual(
            (self.tool_store / "previous").resolve(), original_release
        )
        self.assertEqual(
            sorted(path.name for path in (self.tool_store / "releases").iterdir()),
            sorted(
                [
                    os.path.basename(os.readlink(current)),
                    os.path.basename(os.readlink(self.tool_store / "previous")),
                ]
            ),
        )
        self.assertFalse(
            (self.tool_store / ".incoming").exists()
            and any((self.tool_store / ".incoming").iterdir())
        )
        properties = (current / "conf" / "application-prodv2.properties").read_text()
        self.assertIn("lcm.depot.adapter.host=dl.broadcom.com", properties)
        self.assertEqual(
            self.get("/api/registration").get_json()["machineId"], verified_id
        )
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), verified_id
        )
        self.assertEqual(archive.read_bytes(), before)
        self.assertEqual(
            sorted(path.name for path in depot_tree.iterdir()), tree_before
        )
        status = self.get("/api/status").get_json()
        self.assertEqual(status["vcfdtVersion"], "9.1.0.0400.25570101")

        for directory in locked:
            directory.chmod(0o755)
        bogus = self.seed_depot_tool("9.2.0", machine_id="fake")
        bogus.write_bytes(self.tar_tool(version="fake", machine_id="fake").getvalue())
        response = self.install_from_depot(bogus.name)
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.get_json()["version"], "unverified")
        self.assertFalse(response.get_json()["versionVerified"])
        releases = list((self.tool_store / "releases").iterdir())
        self.assertEqual(len(releases), 2)
        self.assertEqual(
            self.get("/api/vcfdt").get_json()["previous"]["version"],
            "9.1.0.0400.25570101",
        )
        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 409)
        self.assertEqual(registration.get_json()["machineId"], verified_id)

    def test_tool_rollback_swaps_current_and_previous_under_the_update_lock(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        original_target = (self.tool_store / "current").resolve()
        archive = self.seed_depot_tool("9.1.0.0400.25570101")
        self.assertEqual(self.install_from_depot(archive.name).status_code, 201)
        replacement_target = (self.tool_store / "current").resolve()

        response = self.post("/api/vcfdt/rollback")
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(body["version"], "9.1.2")
        self.assertEqual(body["previous"]["version"], "9.1.0.0400.25570101")
        self.assertEqual((self.tool_store / "current").resolve(), original_target)
        self.assertEqual((self.tool_store / "previous").resolve(), replacement_target)

        current = self.get("/api/vcfdt").get_json()
        self.write_state(
            depotContentToolVersion=current["version"],
            depotContentToolReleaseId=current["releaseId"],
            finishedAt="2099-01-01T00:00:00Z",
            lastRun={"esx": {"status": "FAILED:23", "toolVersion": current["version"]}},
        )
        self.assertEqual(self.get("/api/status").status_code, 200)
        self.assertTrue((self.tool_store / "previous").exists())

        self.write_state(running=True)
        refused = self.post("/api/vcfdt/rollback")
        self.assertEqual(refused.status_code, 409)
        self.assertIn("running sync", refused.get_json()["error"])

    def test_tool_rollback_revalidates_adopted_identity(self):
        self.claim()
        self.write_state()
        adopted_id = "22222222-2222-4222-8222-222222222222"
        replacement_id = "33333333-3333-4333-8333-333333333333"
        adopted = self.post(
            "/api/registration/adopt", json={"machineId": adopted_id}
        )
        self.assertEqual(adopted.status_code, 200)
        installed = self.post(
            "/api/vcfdt",
            data={
                "archive": (
                    self.tar_tool(machine_id_file=self.vcfdt_state / "machine_id"),
                    "vcf-download-tool-9.1.2.tar.gz",
                )
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(installed.status_code, 201)
        self.assertEqual(
            installed.get_json()["registration"]["machineIdStatus"], "confirmed"
        )

        archive = self.seed_depot_tool("9.2.0", machine_id=replacement_id)
        replacement = self.install_from_depot(archive.name)
        self.assertEqual(replacement.status_code, 201)
        self.assertEqual(
            replacement.get_json()["registration"]["machineIdStatus"], "mismatch"
        )
        self.assertEqual(self.get("/api/registration").status_code, 409)

        rolled_back = self.post("/api/vcfdt/rollback")
        self.assertEqual(rolled_back.status_code, 200)
        self.forbid_tool_launch()
        registration = self.get("/api/registration")
        self.assertEqual(registration.status_code, 200)
        self.assertEqual(registration.get_json()["machineId"], adopted_id)
        self.assertEqual(registration.get_json()["machineIdStatus"], "confirmed")
        metadata = json.loads(self.current_release_metadata().read_text())
        self.assertEqual(metadata["machineId"], adopted_id)
        self.assertTrue(metadata["machineIdProbed"])

    def test_status_poll_preserves_previous_release_after_successful_sync(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        original_target = (self.tool_store / "current").resolve()
        archive = self.seed_depot_tool("9.1.0.0400.25570101")
        self.assertEqual(self.install_from_depot(archive.name).status_code, 201)
        current = self.get("/api/vcfdt").get_json()
        self.write_state(
            lastRun={
                "patches": {
                    "status": "OK",
                    "toolVersion": current["version"],
                    "toolReleaseId": current["releaseId"],
                }
            },
            finishedAt="2099-09-08T12:00:00Z",
        )

        status = self.get("/api/status")
        self.assertEqual(status.status_code, 200)
        self.assertEqual(
            status.get_json()["lastRun"]["patches"]["toolVersion"], "9.1.0.0400.25570101"
        )
        self.assertTrue((self.tool_store / "previous").exists())
        self.assertTrue(original_target.exists())
        self.assertIsNotNone(self.get("/api/vcfdt").get_json()["previous"])

    @unittest.skipUnless(shutil.which("node"), "Node is required to execute console JavaScript")
    def test_console_renders_per_target_tool_versions_for_partial_runs(self):
        self.claim()
        self.write_state(
            depotContentToolVersion="stale-summary",
            depotContentToolReleaseId="stale-release",
            lastRun={
                "esx": {"status": "OK", "toolVersion": "B"},
                "install": {"status": "FAILED:23", "toolVersion": "B"},
                "patches": {"status": "OK", "toolVersion": "A"},
                "upgrade": {"status": "OK"},
            },
        )
        payload = {
            "html": self.get("/").get_data(as_text=True),
            "status": self.get("/api/status").get_json(),
        }
        self.assertNotIn("depotContentToolVersion", payload["status"])
        self.assertNotIn("depotContentToolReleaseId", payload["status"])
        result = subprocess.run(
            ["node", str(APP_PATH.parents[1] / "tests" / "console-status.cjs")],
            input=json.dumps(payload), text=True, capture_output=True, check=True,
        )
        rendered = json.loads(result.stdout)
        self.assertEqual(rendered["error"], "")
        self.assertIn("esx: tool B (OK)", rendered["summary"])
        self.assertIn("install: tool B (FAILED:23)", rendered["summary"])
        self.assertIn("patches: tool A (OK)", rendered["summary"])
        self.assertIn("upgrade: tool unknown (OK)", rendered["summary"])
        self.assertNotIn("stale-summary", rendered["summary"])
        self.assertIn("tool A", rendered["rows"])
        self.assertIn("tool B", rendered["rows"])
        self.assertIn("FAILED:23", rendered["rows"])
        self.assertIn("tool unknown", rendered["rows"])

    def test_install_from_depot_refuses_paths_outside_the_vcfdt_tree(self):
        self.claim()
        self.write_state()
        self.assertEqual(self.upload_tool().status_code, 201)
        original = os.readlink(self.tool_store / "current")
        self.seed_depot_tool("9.1.0.0.25371089")
        self.seed_depot_tool("9.1.0.0400.25570101", subdir="9.1.0.0400.25570101")
        outside = self.depot / "PROD" / "COMP" / "ESX_HOST"
        outside.mkdir(parents=True)
        stray = outside / "vcf-download-tool-9.9.9.tar.gz"
        stray.write_bytes(self.tar_tool(version="9.9.9").getvalue())
        (self.depot / "PROD" / "COMP" / "VCFDT" / "linked.tar.gz").symlink_to(stray)
        (self.depot / "PROD" / "COMP" / "VCFDT" / "escape").symlink_to(outside)
        (self.depot / "PROD" / "COMP" / "VCFDT" / "metadata.json").write_text("{}")

        for path in (
            "../ESX_HOST/vcf-download-tool-9.9.9.tar.gz",
            str(stray),
            "linked.tar.gz",
            "escape/vcf-download-tool-9.9.9.tar.gz",
            "9.1.0.0400.25570101/vcf-download-tool-9.1.0.0400.25570101.tar.gz",
            "9.1.0.0400.25570101\\vcf-download-tool-9.1.0.0400.25570101.tar.gz",
            "metadata.json",
            "missing.tar.gz",
            "",
            None,
            "a/b/c.tar.gz",
            "a\u0000b.tar.gz",
        ):
            response = self.install_from_depot(path)
            self.assertEqual(response.status_code, 400, path)
            self.assertIn("error", response.get_json())
        array_body = self.post(
            "/api/vcfdt/depot", json=["vcf-download-tool-9.1.0.0.25371089.tar.gz"]
        )
        self.assertEqual(array_body.status_code, 400)
        self.assertEqual(os.readlink(self.tool_store / "current"), original)
        self.assertEqual(self.get("/api/status").get_json()["vcfdtVersion"], "9.1.2")

    def test_install_from_depot_is_refused_during_a_running_sync(self):
        self.claim()
        self.write_state(running=True)
        archive = self.seed_depot_tool("9.1.0.0.25371089")
        response = self.install_from_depot(archive.name)
        self.assertEqual(response.status_code, 409)
        self.assertIn("running sync", response.get_json()["error"])
        self.assertFalse((self.tool_store / "current").exists())
        self.assertEqual(self.get("/api/vcfdt/depot").status_code, 200)

    def test_registration_reads_machine_id_and_saves_activation_secret(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        status = self.get("/api/registration").get_json()
        self.assertEqual(status["machineId"], "11111111-1111-4111-8111-111111111111")
        saved = self.post(
            "/api/registration", json={"activationCode": "licensed-secret-value"}
        )
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(
            (self.secrets / "activation-code.txt").read_text(),
            "licensed-secret-value\n",
        )
        self.assertNotIn("licensed-secret-value", saved.get_data(as_text=True))

    def test_adopt_before_install_is_confirmed_by_first_tool_probe(self):
        self.claim()
        self.write_state()
        adopted_id = "22222222-2222-4222-8222-222222222222"

        adopted = self.post(
            "/api/registration/adopt", json={"machineId": adopted_id}
        )
        self.assertEqual(adopted.status_code, 200)
        self.assertEqual(adopted.get_json()["status"], "adopted")
        self.assertFalse(adopted.get_json()["confirmed"])
        self.assertEqual(
            (self.vcfdt_state / "machine_id").read_text(), adopted_id
        )
        self.assertEqual((self.vcfdt_state / "machine_id").stat().st_size, 36)
        pending = self.get("/api/bootstrap").get_json()
        self.assertEqual(pending["machineId"], adopted_id)
        self.assertEqual(pending["machineIdStatus"], "adopted")
        self.assertIn("first tool install", pending["machineIdMessage"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        refused_activation = self.post(
            "/api/registration", json={"activationCode": "premature-code"}
        )
        self.assertEqual(refused_activation.status_code, 409)
        self.assertFalse((self.secrets / "activation-code.txt").exists())

        installed = self.post(
            "/api/vcfdt",
            data={
                "archive": (
                    self.tar_tool(
                        machine_id_file=self.vcfdt_state / "machine_id"
                    ),
                    "vcf-download-tool-9.1.2.tar.gz",
                )
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(installed.status_code, 201)
        self.assertEqual(
            installed.get_json()["registration"]["machineIdStatus"], "confirmed"
        )
        confirmed = self.get("/api/bootstrap").get_json()
        self.assertEqual(confirmed["machineId"], adopted_id)
        self.assertEqual(confirmed["machineIdStatus"], "confirmed")
        self.assertIn("Confirmed", confirmed["machineIdMessage"])

    def test_pending_adoption_uses_durable_record_across_workers(self):
        self.claim()
        self.write_state()
        first_id = "22222222-2222-4222-8222-222222222222"
        corrected_id = "33333333-3333-4333-8333-333333333333"
        adopted = self.post(
            "/api/registration/adopt", json={"machineId": first_id}
        )
        self.assertEqual(adopted.status_code, 200)

        self.assertEqual(
            self.get("/api/bootstrap").get_json()["machineId"], first_id
        )
        self.module._write_secret(self.module.VCFDT_MACHINE_ID_FILE, corrected_id)
        self.module._record_machine_id_adoption(corrected_id, "adopted")

        pending = self.get("/api/bootstrap").get_json()
        self.assertEqual(pending["machineId"], corrected_id)
        self.assertEqual(pending["adoptedMachineId"], corrected_id)
        self.assertEqual(pending["machineIdStatus"], "adopted")
        _worker, client = self.new_worker()
        other = client.get("/api/bootstrap", base_url="https://localhost").get_json()
        self.assertEqual(other["machineId"], corrected_id)
        self.assertEqual(other["machineIdStatus"], "adopted")

    def test_adopt_with_tool_installed_preserves_identity_and_activation(self):
        self.claim()
        self.write_state()
        original_id = "11111111-1111-4111-8111-111111111111"
        adopted_id = "22222222-2222-4222-8222-222222222222"
        self.vcfdt_state.mkdir()
        (self.vcfdt_state / "machine_id").write_text(original_id + "\n")
        installed = self.post(
            "/api/vcfdt",
            data={
                "archive": (
                    self.tar_tool(
                        machine_id_file=self.vcfdt_state / "machine_id"
                    ),
                    "vcf-download-tool-9.1.2.tar.gz",
                )
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(installed.status_code, 201)

        saved = self.post(
            "/api/registration", json={"activationCode": "retained-code"}
        )
        self.assertEqual(saved.status_code, 200)
        response = self.post(
            "/api/registration/adopt", json={"machineId": adopted_id}
        )
        self.assertEqual(response.status_code, 409)
        self.assertIn("before installing", response.get_json()["error"])
        self.assertEqual(
            (self.vcfdt_state / "machine_id").read_text(), original_id + "\n"
        )
        self.assertEqual(
            self.get("/api/registration").get_json()["machineId"], original_id
        )
        self.assertEqual(
            Path(self.module.SOFTWARE_DEPOT_ID_FILE).read_text().strip(), original_id
        )
        self.assertFalse(self.module.SOFTWARE_DEPOT_ADOPTION_FILE.exists())
        self.assertEqual(
            (self.secrets / "activation-code.txt").read_text(), "retained-code\n"
        )

    def test_adopt_before_install_reports_installation_probe_mismatch(self):
        self.claim()
        self.write_state()
        adopted_id = "22222222-2222-4222-8222-222222222222"
        response = self.post(
            "/api/registration/adopt", json={"machineId": adopted_id}
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.upload_tool().status_code, 201)
        status = self.get("/api/bootstrap").get_json()
        self.assertEqual(status["machineIdStatus"], "mismatch")
        self.assertIn(adopted_id, status["machineIdMessage"])
        self.assertIn(
            "11111111-1111-4111-8111-111111111111", status["machineIdMessage"]
        )
        self.assertEqual(self.get("/api/registration").status_code, 409)
        self.assertEqual(
            self.post("/api/registration", json={"activationCode": "wrong-code"}).status_code,
            409,
        )
        self.assertFalse((self.secrets / "activation-code.txt").exists())

    def test_adopt_rejects_invalid_software_depot_id(self):
        self.claim()
        self.write_state()
        for value in (None, "not-a-uuid", "11111111-1111-4111-8111-11111111111"):
            response = self.post(
                "/api/registration/adopt", json={"machineId": value}
            )
            self.assertEqual(response.status_code, 400)
        self.assertFalse((self.vcfdt_state / "machine_id").exists())

    def test_adopt_is_refused_during_running_sync(self):
        self.claim()
        self.write_state(running=True)
        response = self.post(
            "/api/registration/adopt",
            json={"machineId": "22222222-2222-4222-8222-222222222222"},
        )
        self.assertEqual(response.status_code, 409)
        self.assertIn("running sync", response.get_json()["error"])
        self.assertFalse((self.vcfdt_state / "machine_id").exists())

    def test_adopt_is_refused_during_tool_update(self):
        self.claim()
        self.write_state()
        self.tool_store.mkdir()
        lock = (self.tool_store / ".update.lock").open("a+")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        response = self.post(
            "/api/registration/adopt",
            json={"machineId": "22222222-2222-4222-8222-222222222222"},
        )
        self.assertEqual(response.status_code, 409)
        self.assertIn("tool update", response.get_json()["error"])
        self.assertFalse((self.vcfdt_state / "machine_id").exists())

    def test_settings_replace_installer_questions_and_patch_tool_endpoints(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        profile_paths = [
            self.tool_store / "current" / "conf" / profile
            for profile in (
                "application-prod.properties",
                "application-prodv2.properties",
            )
        ]
        original_inodes = {path: path.stat().st_ino for path in profile_paths}
        response = self.post("/api/settings", json=self.valid_settings())
        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(body["cronSchedule"], "0 2 * * 6")
        self.assertTrue(body["storageConfirmed"])
        self.assertEqual(
            body["patchedFiles"],
            [
                "conf/application-prod.properties",
                "conf/application-prodv2.properties",
            ],
        )
        settings_text = self.settings.read_text()
        self.assertNotIn("NFS_", settings_text)
        self.assertIn('DEPOT_ENDPOINT="downloads.example.test"', settings_text)
        for path in profile_paths:
            properties = path.read_text()
            self.assertIn("lcm.depot.adapter.host=downloads.example.test", properties)
            self.assertNotEqual(path.stat().st_ino, original_inodes[path])

    def test_settings_leaves_non_production_profile_untouched(self):
        self.claim()
        self.write_state()
        archive = self.tar_tool(
            profiles={
                "application-prod.properties": (
                    "lcm.depot.adapter.host=old.example.test\n"
                ),
                "application-prodv2.properties": (
                    "lcm.access_token.broadcom.authorization.server.url="
                    "https://old.example.test/token\n"
                ),
                "application-lab.properties": (
                    "unrelated.setting=true\n"
                    "lcm.depot.adapter.host=old.example.test\n"
                ),
            }
        )
        response = self.post(
            "/api/vcfdt",
            data={"archive": (archive, "vcf-download-tool-profiles.tar.gz")},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 201)
        saved = self.post("/api/settings", json=self.valid_settings())
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(
            saved.get_json()["patchedFiles"],
            [
                "conf/application-prod.properties",
                "conf/application-prodv2.properties",
            ],
        )
        lab_profile = self.tool_store / "current" / "conf" / "application-lab.properties"
        self.assertEqual(
            lab_profile.read_text(),
            "unrelated.setting=true\nlcm.depot.adapter.host=old.example.test\n",
        )

    def test_settings_write_failure_restores_profiles_and_settings(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        conf = self.tool_store / "current" / "conf"
        profiles = sorted(conf.glob("application-prod*.properties"))
        originals = {path: path.read_bytes() for path in profiles}
        modes = {path: path.stat().st_mode for path in profiles}
        settings_before = self.settings.read_bytes()
        replace = os.replace
        for failed_path in (profiles[1], self.settings):
            with self.subTest(failed_path=failed_path.name):
                replaced = []

                def fail_write(source, destination):
                    destination = Path(destination)
                    if destination == failed_path:
                        raise OSError("injected write failure")
                    replace(source, destination)
                    replaced.append(destination)

                with mock.patch.object(self.module.os, "replace", side_effect=fail_write):
                    response = self.post("/api/settings", json=self.valid_settings())
                self.assertEqual(response.status_code, 500)
                self.assertIn("injected write failure", response.get_json()["error"])
                self.assertIn(profiles[0], replaced)
                for path in profiles:
                    self.assertEqual(path.read_bytes(), originals[path])
                    self.assertEqual(path.stat().st_mode, modes[path])
                self.assertEqual(self.settings.read_bytes(), settings_before)
                self.assertEqual(sorted(conf.glob(".*")), [])
                settings = self.get("/api/settings").get_json()
                self.assertEqual(settings["depotEndpoint"], "dl.broadcom.com")
                self.assertEqual(
                    settings["tokenUrl"], "https://eapi.broadcom.com/vcf/generateToken"
                )

    def test_settings_no_key_error_preserves_stored_endpoints(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        current = self.tool_store / "current"
        for properties in (current / "conf").glob("application*.properties"):
            properties.write_text("unrelated.setting=true\n")
        response = self.post("/api/settings", json=self.valid_settings())
        self.assertEqual(response.status_code, 409)
        self.assertIn("no VCF Download Tool endpoint keys", response.get_json()["error"])
        self.assertIn('DEPOT_ENDPOINT="dl.broadcom.com"', self.settings.read_text())

    def test_sync_diagnostics_default_off_and_saved_to_settings_env(self):
        self.claim()
        self.write_state()
        self.assertFalse(self.get("/api/settings").get_json()["syncDiagnostics"])
        self.assertNotIn("SYNC_DIAGNOSTICS", self.settings.read_text())
        saved = self.post("/api/settings", json={"syncDiagnostics": True})
        self.assertEqual(saved.status_code, 200)
        self.assertTrue(saved.get_json()["syncDiagnostics"])
        self.assertIn('SYNC_DIAGNOSTICS="true"\n', self.settings.read_text())
        self.assertTrue(self.get("/api/settings").get_json()["syncDiagnostics"])
        cleared = self.post("/api/settings", json={"syncDiagnostics": False})
        self.assertEqual(cleared.status_code, 200)
        self.assertFalse(cleared.get_json()["syncDiagnostics"])
        self.assertIn('SYNC_DIAGNOSTICS="false"\n', self.settings.read_text())
        rejected = self.post("/api/settings", json={"syncDiagnostics": "yes"})
        self.assertEqual(rejected.status_code, 400)
        self.assertIn("true or false", rejected.get_json()["error"])

    def test_partial_settings_update_merges_over_stored_document(self):
        self.claim()
        self.write_state()
        response = self.post("/api/settings", json={"cronSchedule": "30 2 * * *"})
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
        refused = self.post("/api/settings", json={"cronSchedule": "30 2 * * *"})
        self.assertEqual(refused.status_code, 409)
        self.assertIn("Startup is blocked", refused.get_json()["error"])
        self.assertEqual(self.get("/api/registration").status_code, 409)
        depot_auth = self.get(
            "/auth/check",
            headers={"Authorization": "Basic dmNmOmEgc3Ryb25nIHRlc3QgcGFzc3dvcmQ="},
        )
        self.assertEqual(depot_auth.status_code, 503)

    def test_bootstrap_reports_the_last_config_migration(self):
        self.claim()
        migration = {
            "status": "completed",
            "fromSchema": 0,
            "toSchema": 1,
            "fromVersion": "v0.1.0",
            "toVersion": "v0.2.1",
            "backupPath": "/config/migration-backups/test",
            "migratedAt": "2026-09-08T12:00:00+00:00",
        }
        Path(self.module.MIGRATION_STATUS_FILE).write_text(json.dumps(migration))
        response = self.get("/api/bootstrap")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["migration"], migration)

    def test_settings_reject_bad_schedule_and_bad_uid(self):
        self.claim()
        self.write_state()
        body = self.valid_settings()
        body["cronSchedule"] = "bad"
        self.assertEqual(self.post("/api/settings", json=body).status_code, 400)
        body = self.valid_settings()
        body["cronSchedule"] = "0 3 * * $(id)"
        self.assertEqual(self.post("/api/settings", json=body).status_code, 400)
        # A weekly picker with no weekday composes an empty day-of-week field.
        body = self.valid_settings()
        body["cronSchedule"] = "30 6 * * "
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

    def test_settings_save_during_a_running_sync_applies_to_the_next_run(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        self.write_state(running=True, armed=True, startedAt="2026-09-06T10:00:00Z")
        body = self.valid_settings()
        body["depotEndpoint"] = "dl.broadcom.com"
        body["tokenUrl"] = "https://eapi.broadcom.com/vcf/generateToken"
        response = self.post("/api/settings", json=body)
        self.assertEqual(response.status_code, 200)
        saved = response.get_json()
        self.assertTrue(saved["appliesToNextRun"])
        self.assertIn("cronSchedule", saved["pendingFields"])
        self.assertEqual(saved["cronSchedule"], "0 2 * * 6")
        settings_text = self.settings.read_text()
        self.assertIn('CRON_SCHEDULE="0 2 * * 6"', settings_text)
        self.assertIn('VKR_OS="photon"', settings_text)
        properties = (
            self.tool_store / "current" / "conf" / "application-prodv2.properties"
        ).read_text()
        self.assertIn("lcm.depot.adapter.host=dl.broadcom.com", properties)

        status = self.get("/api/status").get_json()
        self.assertTrue(status["appliesToNextRun"])
        self.assertIn("cronSchedule", status["pendingFields"])

        blocked = self.post(
            "/api/settings", json={"depotEndpoint": "downloads.example.test"}
        )
        self.assertEqual(blocked.status_code, 409)
        self.assertIn("depotEndpoint", blocked.get_json()["error"])
        self.assertIn('DEPOT_ENDPOINT="dl.broadcom.com"', self.settings.read_text())

        self.write_state(running=False, armed=True)
        idle = self.get("/api/settings").get_json()
        self.assertFalse(idle["appliesToNextRun"])
        self.assertEqual(idle["pendingFields"], [])
        applied = self.post(
            "/api/settings", json={"depotEndpoint": "downloads.example.test"}
        )
        self.assertEqual(applied.status_code, 200)
        self.assertFalse(applied.get_json()["appliesToNextRun"])
        properties = (
            self.tool_store / "current" / "conf" / "application-prodv2.properties"
        ).read_text()
        self.assertIn("lcm.depot.adapter.host=downloads.example.test", properties)

    def test_settings_saved_before_a_run_publishes_its_state_wait_for_next_run(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        lock_path = self.state_dir / "settings-snapshot.lock"
        lock_path.touch()
        body = self.valid_settings()
        body["depotEndpoint"] = "dl.broadcom.com"
        body["tokenUrl"] = "https://eapi.broadcom.com/vcf/generateToken"
        # A run holds the snapshot lock from before it reads settings.env until
        # it exits, so a save that lands before the run publishes running state
        # is still reported as applying to the next run.
        with open(lock_path, "r", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            response = self.post("/api/settings", json=body)
            self.assertEqual(response.status_code, 200)
            saved = response.get_json()
            self.assertTrue(saved["appliesToNextRun"])
            self.assertIn("cronSchedule", saved["pendingFields"])
            self.assertIn('CRON_SCHEDULE="0 2 * * 6"', self.settings.read_text())
            self.assertTrue(self.get("/api/status").get_json()["appliesToNextRun"])
            blocked = self.post(
                "/api/settings", json={"depotEndpoint": "downloads.example.test"}
            )
            self.assertEqual(blocked.status_code, 409)
            self.assertIn("depotEndpoint", blocked.get_json()["error"])
            fcntl.flock(handle, fcntl.LOCK_UN)
        idle = self.get("/api/settings").get_json()
        self.assertFalse(idle["appliesToNextRun"])
        self.assertEqual(idle["pendingFields"], [])

    def test_a_pending_save_does_not_carry_into_the_next_run(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        lock_path = self.state_dir / "settings-snapshot.lock"
        lock_path.touch()
        run_file = self.state_dir / "settings-snapshot.run"
        body = self.valid_settings()
        body["depotEndpoint"] = "dl.broadcom.com"
        body["tokenUrl"] = "https://eapi.broadcom.com/vcf/generateToken"
        # sync.sh names the run before it takes the lock, so a save that lands
        # in the gap before the run publishes its state is still tagged with
        # that run.
        run_file.write_text("run-one\n")
        with open(lock_path, "r", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            saved = self.post("/api/settings", json=body).get_json()
            self.assertTrue(saved["appliesToNextRun"])
            self.assertIn("cronSchedule", saved["pendingFields"])
            fcntl.flock(handle, fcntl.LOCK_UN)

        # The second run reads those values at its own start, so they are in
        # use rather than waiting for a later run.
        run_file.write_text("run-two\n")
        with open(lock_path, "r", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            self.write_state(running=True, armed=True, startedAt="2026-09-06T12:00:00Z")
            status = self.get("/api/status").get_json()
            self.assertFalse(status["appliesToNextRun"])
            self.assertEqual(status["pendingFields"], [])
            settings_view = self.get("/api/settings").get_json()
            self.assertFalse(settings_view["appliesToNextRun"])
            self.assertEqual(settings_view["pendingFields"], [])
            # A save made during the second run is pending for that run only.
            body["logRetention"] = 42
            during = self.post("/api/settings", json=body).get_json()
            self.assertTrue(during["appliesToNextRun"])
            self.assertEqual(during["pendingFields"], ["logRetention"])
            fcntl.flock(handle, fcntl.LOCK_UN)

    def test_live_backup_settings_are_not_reported_as_next_run(self):
        self.claim()
        self.write_state()
        self.upload_tool()
        self.write_state(running=True, armed=True, startedAt="2026-09-06T11:00:00Z")
        # The SFTP service re-reads these every few seconds, so they are live.
        live_only = self.post(
            "/api/settings", json={"backupEnabled": True, "uidGid": "1500:1500"}
        )
        self.assertEqual(live_only.status_code, 200)
        saved = live_only.get_json()
        self.assertEqual(saved["appliedNow"], ["backupEnabled", "uidGid"])
        self.assertFalse(saved["appliesToNextRun"])
        self.assertEqual(saved["pendingFields"], [])
        settings_text = self.settings.read_text()
        self.assertIn('BACKUP_ENABLED="true"', settings_text)
        self.assertIn('SFTP_UID_GID="1500:1500"', settings_text)

        body = self.valid_settings()
        body["depotEndpoint"] = "dl.broadcom.com"
        body["tokenUrl"] = "https://eapi.broadcom.com/vcf/generateToken"
        mixed = self.post("/api/settings", json=body).get_json()
        self.assertEqual(mixed["appliedNow"], ["uidGid"])
        self.assertTrue(mixed["appliesToNextRun"])
        self.assertIn("cronSchedule", mixed["pendingFields"])
        self.assertNotIn("uidGid", mixed["pendingFields"])
        self.assertNotIn("backupEnabled", mixed["pendingFields"])
        self.assertIn('SFTP_UID_GID="1004:1005"', self.settings.read_text())

    def test_console_tabs_render_every_control(self):
        self.claim()
        page = self.get("/")
        self.assertEqual(page.status_code, 200)
        panels, controls = parse_console_tabs(page.get_data(as_text=True))
        self.assertEqual(
            panels,
            [
                "tab-setup",
                "tab-sync",
                "tab-depot",
                "tab-settings",
                "tab-backup",
                "tab-logs",
            ],
        )
        expected = {
            "tab-setup": {
                "vcfdt-depot-version",
                "vcfdt-depot-install",
                "vcfdt-depot-refresh",
                "vcfdt-rollback",
                "vcfdt-archive",
                "vcfdt-upload",
                "adopt-machine-id",
                "adopt-machine-id-button",
                "verify-machine-id",
                "activation-code",
                "save-activation",
                "storage-confirmed",
                "finish-setup",
                "download-ca",
                "current-password",
                "new-password",
                "save-password",
            },
            "tab-sync": {"sync-btn", "refresh-remote"},
            "tab-depot": {
                "depot-refresh",
                "depot-up",
                "depot-path",
                "depot-browse",
                "depot-upload",
                "depot-extract",
                "depot-upload-button",
                "depot-delete-confirm",
                "depot-delete-button",
                "depot-delete-cancel",
            },
            "tab-settings": {
                "vcf-version",
                "sku",
                "schedule-mode",
                "schedule-hour",
                "schedule-minute",
                "cron-advanced",
                "cron",
                "timezone",
                "ceip",
                "esx-mode",
                "log-retention",
                "sync-diagnostics",
                "depot-endpoint",
                "token-url",
                "vkr-match",
                "vkr-os",
                "save-settings",
            },
            "tab-backup": {"backup-enabled", "uidgid", "save-backup"},
            "tab-logs": set(),
        }
        self.assertEqual({name: set(ids) for name, ids in controls.items()}, expected)
        for name, ids in controls.items():
            self.assertEqual(len(ids), len(set(ids)), f"duplicate ids in {name}")
        body = page.get_data(as_text=True)
        for target in self.module.VALID_TARGETS:
            self.assertIn(f'class="run-target" value="{target}"', body)
            self.assertIn(f'class="settings-target" value="{target}"', body)
        self.assertIn('id="settings-pending"', body)
        self.assertIn('id="backup-pending"', body)
        # The schedule picker: one weekday box per day, the next-run readout,
        # and the raw cron input kept behind the advanced toggle.
        self.assertEqual(body.count('class="schedule-weekday"'), 7)
        for day in range(7):
            self.assertIn(f'class="schedule-weekday" value="{day}"', body)
        self.assertIn('id="schedule-weekdays"', body)
        self.assertIn('id="schedule-next"', body)
        self.assertIn('id="cron-wrap" hidden', body)
        self.assertIn('id="log"', body)
        self.assertIn('id="versions"', body)
        self.assertIn('id="vcfdt-previous"', body)
        self.assertIn('id="vcfdt-produced"', body)
        self.assertIn('id="migration-result"', body)
        self.assertIn('id="verify-flash"', body)
        self.assertIn('id="auth-flash" class="error" role="status"', body)
        self.assertIn("again on its own at appliance start", body)

    def test_depot_ownership_errors_refuse_reads_and_mutations(self):
        self.claim()
        tree = self.depot / "PROD" / "COMP" / "ESX_HOST"
        tree.mkdir(parents=True)
        sentinel = tree / "operator.bin"
        sentinel.write_bytes(b"operator")
        manifest = self.module.DEPOT_OWNERSHIP_FILE
        valid = {"version": 1, "trees": {
            "ESX_HOST": {"ownership": "operator-provided", "protected": True}
        }}
        invalid_documents = [
            [], {}, {"version": 2, "trees": {}},
            {"version": True, "trees": {}}, {"version": 1, "trees": []},
        ]
        for entry in (
            None, {}, {"ownership": "invalid", "protected": True},
            {"ownership": [], "protected": True},
            {"ownership": "operator-provided"},
            {"ownership": "operator-provided", "protected": "false"},
            {"ownership": "operator-provided", "protected": 0},
        ):
            invalid_documents.append({"version": 1, "trees": {"ESX_HOST": entry}})
        invalid_documents.append({"version": 1, "trees": {
            "ESX_HOST/child": valid["trees"]["ESX_HOST"]
        }})
        cases = [("unreadable", json.dumps(valid).encode()),
                 ("invalid-json", b"{broken"), ("empty", b""),
                 ("invalid-encoding", b"\xff")]
        cases += [(f"schema-{index}", json.dumps(document).encode())
                  for index, document in enumerate(invalid_documents)]
        original_read = Path.read_text
        for failure, stored in cases:
            with self.subTest(failure=failure):
                manifest.write_bytes(stored)

                def read_text(path, *args, **kwargs):
                    if failure == "unreadable" and path == manifest:
                        raise PermissionError("ownership state is unreadable")
                    return original_read(path, *args, **kwargs)

                operations = (
                    lambda: self.get("/api/depot/ownership"),
                    lambda: self.get("/api/depot/tree?path=PROD/COMP/ESX_HOST"),
                    lambda: self.post("/api/depot/ownership", json={
                        "name": "ESX_HOST", "protected": False,
                    }),
                    lambda: self.post("/api/depot/upload", data={
                        "path": "PROD/COMP/ESX_HOST",
                        "upload": (io.BytesIO(b"new"), "new.bin"),
                    }, content_type="multipart/form-data"),
                    lambda: self.delete("/api/depot/entry", json={
                        "path": "PROD/COMP/ESX_HOST",
                        "confirm": "PROD/COMP/ESX_HOST",
                    }),
                )
                with mock.patch.object(Path, "read_text", read_text):
                    for operation in operations:
                        response = operation()
                        self.assertIn(response.status_code, (400, 500), response.get_json())
                        self.assertIn("ownership", response.get_json()["error"])
                        self.assertEqual(manifest.read_bytes(), stored)
                        self.assertEqual(sentinel.read_bytes(), b"operator")
                        self.assertFalse((tree / "new.bin").exists())
                        self.assertEqual(list(self.depot.glob(".vcf-services-upload-*")), [])

    def test_depot_dangling_ownership_manifest_is_not_initialized(self):
        self.claim()
        self.seed_content_library()
        manifest = self.module.DEPOT_OWNERSHIP_FILE
        missing = self.state_dir / "missing-ownership.json"
        manifest.symlink_to(missing)

        response = self.get("/api/depot/ownership")

        self.assertEqual(response.status_code, 500, response.get_json())
        self.assertTrue(manifest.is_symlink())
        self.assertFalse(missing.exists())

    def test_content_library_is_inventoried_and_protected_by_default(self):
        self.claim()
        tree = self.seed_content_library()

        response = self.get("/api/depot/ownership")

        self.assertEqual(response.status_code, 200)
        row = response.get_json()["trees"][0]
        self.assertEqual(row["name"], "SUPERVISOR")
        self.assertEqual(row["path"], "PROD/COMP/SUPERVISOR")
        self.assertEqual(row["ownership"], "operator-provided")
        self.assertTrue(row["protected"])
        self.assertTrue(row["contentLibrary"])
        self.assertEqual(row["itemCount"], 2)
        self.assertEqual(row["fileCount"], 3)
        self.assertEqual(
            row["sizeBytes"], sum(path.stat().st_size for path in tree.iterdir())
        )
        manifest = json.loads(
            (self.state_dir / "depot-ownership.json").read_text()
        )
        self.assertEqual(
            manifest["trees"]["SUPERVISOR"],
            {"ownership": "operator-provided", "protected": True},
        )

        unprotected = self.post(
            "/api/depot/ownership",
            json={"name": "SUPERVISOR", "protected": False},
        )
        self.assertEqual(unprotected.status_code, 200)
        self.assertFalse(unprotected.get_json()["protected"])
        refreshed = self.get("/api/depot/ownership").get_json()["trees"][0]
        self.assertEqual(refreshed["ownership"], "operator-provided")
        self.assertFalse(refreshed["protected"])

    def test_depot_tree_refuses_traversal_and_symlink_escape(self):
        self.claim()
        (self.depot / "safe").mkdir()
        (self.depot / "safe" / "file.bin").write_bytes(b"safe")
        outside = self.depot.parent / "outside"
        outside.mkdir()
        (self.depot / "escape").symlink_to(outside)

        listing = self.get("/api/depot/tree?path=safe")

        self.assertEqual(listing.status_code, 200)
        self.assertEqual(listing.get_json()["entries"][0]["path"], "safe/file.bin")
        for unsafe in ("../outside", "/etc", "escape", "safe/../../outside"):
            response = self.get(
                "/api/depot/tree", query_string={"path": unsafe}
            )
            self.assertEqual(response.status_code, 400, unsafe)

        for unsafe in ("../outside", "/etc", "escape"):
            response = self.post(
                "/api/depot/upload",
                data={
                    "path": unsafe,
                    "upload": (io.BytesIO(b"blocked"), "blocked.bin"),
                },
                content_type="multipart/form-data",
            )
            self.assertEqual(response.status_code, 400, unsafe)
        delete_link = self.delete(
            "/api/depot/entry", json={"path": "escape", "confirm": "escape"}
        )
        self.assertEqual(delete_link.status_code, 400)
        self.assertTrue(outside.exists())

    def test_depot_contained_patch_store_link_uploads_and_protection(self):
        self.claim()
        backing = "PROD/COMP/ESX_HOST/patch-store"
        patch_store = self.depot / backing
        patch_store.mkdir(parents=True)
        (self.depot / "umds-patch-store").symlink_to(backing)
        (self.depot / "patch-store-private").mkdir()
        (self.depot / "component-alias").symlink_to("PROD/COMP")
        for index, destination in enumerate(("umds-patch-store", backing)):
            with self.subTest(destination=destination):
                listing = self.get(
                    "/api/depot/tree", query_string={"path": destination}
                )
                self.assertEqual(listing.status_code, 200)
                self.assertTrue(listing.get_json()["publicDownload"])
                for extract in (False, True):
                    name = f"uploaded-{index}-{extract}.txt"
                    payload = io.BytesIO(b"content")
                    filename = name
                    if extract:
                        payload = io.BytesIO()
                        with zipfile.ZipFile(payload, "w") as archive:
                            archive.writestr(name, b"content")
                        payload.seek(0)
                        filename = "content.zip"
                    response = self.post(
                        "/api/depot/upload",
                        data={"path": destination, "extract": str(extract).lower(),
                              "upload": (payload, filename)},
                        content_type="multipart/form-data",
                    )
                    self.assertEqual(response.status_code, 201, response.get_json())
                    self.assertTrue(response.get_json()["publicDownload"])
                    self.assertIn("downloadable without credentials", response.get_json()["notice"])
                    self.assertEqual((patch_store / name).read_bytes(), b"content")
        root = self.get("/api/depot/tree").get_json()
        entry = next(row for row in root["entries"] if row["name"] == "umds-patch-store")
        self.assertEqual(entry["type"], "directory")
        self.assertEqual((entry["sizeBytes"], entry["fileCount"]), (28, 4))
        private = self.post(
            "/api/depot/upload",
            data={"path": "patch-store-private", "upload": (io.BytesIO(b"private"), "file")},
            content_type="multipart/form-data",
        )
        self.assertEqual(private.status_code, 201)
        self.assertFalse(private.get_json()["publicDownload"])
        protected = self.post(
            "/api/depot/ownership", json={"name": "ESX_HOST", "protected": True}
        )
        self.assertEqual(protected.status_code, 200)
        for destination in ("umds-patch-store", backing):
            response = self.post(
                "/api/depot/upload",
                data={"path": destination, "upload": (io.BytesIO(b"blocked"), "blocked")},
                content_type="multipart/form-data",
            )
            self.assertEqual(response.status_code, 400)
            self.assertIn("unprotect PROD/COMP/ESX_HOST", response.get_json()["error"])
        for relative in ("umds-patch-store/uploaded-0-False.txt", "component-alias/ESX_HOST"):
            response = self.delete(
                "/api/depot/entry", json={"path": relative, "confirm": relative}
            )
            self.assertEqual(response.status_code, 400)
            self.assertIn("unprotect PROD/COMP/ESX_HOST", response.get_json()["error"])
        self.assertFalse((patch_store / "blocked").exists())
        self.assertEqual((patch_store / "uploaded-0-False.txt").read_bytes(), b"content")

    def test_depot_public_notice_for_link_and_directory_restores(self):
        self.claim()
        backing = "PROD/COMP/ESX_HOST/patch-store"
        patch_store = self.depot / backing
        patch_store.mkdir(parents=True)
        public_link = self.depot / "umds-patch-store"
        public_link.symlink_to(backing)
        shapes = (
            (None, "umds-patch-store", "restored.bin"),
            (backing, "PROD/COMP/ESX_HOST", "patch-store/restored.bin"),
            ("PROD/COMP/ESX_HOST", "PROD/COMP", "ESX_HOST/patch-store/restored.bin"),
        )
        for removed, destination, member in shapes:
            with self.subTest(destination=destination):
                if removed:
                    deleted = self.delete(
                        "/api/depot/entry", json={"path": removed, "confirm": removed}
                    )
                    self.assertEqual(deleted.status_code, 200, deleted.get_json())
                    self.assertTrue(public_link.is_symlink())
                    self.assertFalse(public_link.exists())
                    payload = io.BytesIO()
                    with zipfile.ZipFile(payload, "w") as package:
                        package.writestr(member, b"restored content")
                    payload.seek(0)
                    filename = "restore.zip"
                else:
                    payload = io.BytesIO(b"restored content")
                    filename = member

                response = self.post(
                    "/api/depot/upload",
                    data={
                        "path": destination,
                        "extract": "true" if removed else "false",
                        "upload": (payload, filename),
                    },
                    content_type="multipart/form-data",
                )

                self.assertEqual(response.status_code, 201, response.get_json())
                self.assertTrue(response.get_json()["publicDownload"])
                self.assertIn(
                    "downloadable without credentials", response.get_json()["notice"]
                )
                self.assertEqual(
                    (public_link / "restored.bin").read_bytes(), b"restored content"
                )
                self.assertEqual(public_link.resolve(), patch_store)

    def test_depot_upload_extracts_folder_archive_and_reports_patch_store_notice(self):
        self.claim()
        patch_store = self.depot / "umds-patch-store"
        patch_store.mkdir()
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr("operator-folder/one.txt", b"one")
            package.writestr("operator-folder/two.txt", b"two")
        archive.seek(0)

        response = self.post(
            "/api/depot/upload",
            data={
                "path": "umds-patch-store",
                "extract": "true",
                "upload": (archive, "operator-folder.zip"),
            },
            content_type="multipart/form-data",
        )

        self.assertEqual(response.status_code, 201)
        result = response.get_json()
        self.assertTrue(result["publicDownload"])
        self.assertIn("without credentials", result["notice"])
        self.assertEqual(
            (patch_store / "operator-folder" / "one.txt").read_text(), "one"
        )
        self.assertEqual(
            (patch_store / "operator-folder" / "two.txt").read_text(), "two"
        )

        page = self.get("/").get_data(as_text=True)
        self.assertIn('id="patch-store-notice"', page)
        self.assertIn("downloadable without credentials", page)

    def test_depot_upload_reuses_archive_path_checks_and_refuses_tool_archives(self):
        self.claim()
        unsafe = io.BytesIO()
        with zipfile.ZipFile(unsafe, "w") as package:
            package.writestr("../outside.txt", b"escape")
        unsafe.seek(0)
        response = self.post(
            "/api/depot/upload",
            data={
                "path": "",
                "extract": "true",
                "upload": (unsafe, "unsafe.zip"),
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse((self.depot.parent / "outside.txt").exists())

        licensed = self.post(
            "/api/depot/upload",
            data={
                "path": "",
                "extract": "false",
                "upload": (io.BytesIO(b"licensed"), "vcf-download-tool-9.1.tar.gz"),
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(licensed.status_code, 400)
        self.assertIn("Setup tab", licensed.get_json()["error"])

    def test_depot_paths_preserve_valid_leading_and_trailing_whitespace(self):
        self.claim()
        (self.depot / "umds-patch-store").mkdir()

        uploaded = self.post(
            "/api/depot/upload",
            data={
                "path": "",
                "upload": (io.BytesIO(b"plain"), " file .bin "),
            },
            content_type="multipart/form-data",
        )

        self.assertEqual(uploaded.status_code, 201, uploaded.get_json())
        self.assertEqual((self.depot / " file .bin ").read_bytes(), b"plain")

        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr(" folder / item .bin ", b"archive")
        archive.seek(0)
        extracted = self.post(
            "/api/depot/upload",
            data={
                "path": "",
                "extract": "true",
                "upload": (archive, "whitespace.zip"),
            },
            content_type="multipart/form-data",
        )

        self.assertEqual(extracted.status_code, 201, extracted.get_json())
        self.assertEqual(
            (self.depot / " folder " / " item .bin ").read_bytes(), b"archive"
        )
        names = {
            entry["name"]
            for entry in self.get("/api/depot/tree").get_json()["entries"]
        }
        self.assertIn(" file .bin ", names)
        self.assertIn(" folder ", names)
        deleted = self.delete(
            "/api/depot/entry",
            json={"path": " file .bin ", "confirm": " file .bin "},
        )
        self.assertEqual(deleted.status_code, 200, deleted.get_json())

    def test_depot_archive_rolls_back_when_ownership_cannot_be_recorded(self):
        self.claim()
        component_root = self.depot / "PROD" / "COMP"
        component_root.mkdir(parents=True)

        def operator_archive():
            payload = io.BytesIO()
            with zipfile.ZipFile(payload, "w") as package:
                package.writestr("OPERATOR/lib.json", "{}")
                package.writestr("OPERATOR/items.json", "[]")
            payload.seek(0)
            return payload

        with mock.patch.object(
            self.module,
            "_record_operator_trees",
            side_effect=OSError("state volume is full"),
        ):
            failed = self.post(
                "/api/depot/upload",
                data={
                    "path": "PROD/COMP",
                    "extract": "true",
                    "upload": (operator_archive(), "operator.zip"),
                },
                content_type="multipart/form-data",
            )

        self.assertEqual(failed.status_code, 500, failed.get_json())
        self.assertIn("state volume is full", failed.get_json()["error"])
        self.assertFalse((component_root / "OPERATOR").exists())

        retried = self.post(
            "/api/depot/upload",
            data={
                "path": "PROD/COMP",
                "extract": "true",
                "upload": (operator_archive(), "operator.zip"),
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(retried.status_code, 201, retried.get_json())
        manifest = json.loads(
            (self.state_dir / "depot-ownership.json").read_text()
        )
        self.assertEqual(
            manifest["trees"]["OPERATOR"],
            {"ownership": "operator-provided", "protected": True},
        )

    def test_depot_delete_requires_named_confirmation_and_reports_impact(self):
        self.claim()
        tree = self.depot / "remove-me"
        tree.mkdir()
        (tree / "one.bin").write_bytes(b"123")
        (tree / "two.bin").write_bytes(b"4567")

        listing = self.get("/api/depot/tree").get_json()["entries"]
        entry = next(row for row in listing if row["name"] == "remove-me")
        self.assertEqual(entry["sizeBytes"], 7)
        self.assertEqual(entry["fileCount"], 2)

        refused = self.delete(
            "/api/depot/entry", json={"path": "remove-me", "confirm": "wrong"}
        )
        self.assertEqual(refused.status_code, 400)
        self.assertTrue(tree.exists())

        deleted = self.delete(
            "/api/depot/entry",
            json={"path": "remove-me", "confirm": "remove-me"},
        )
        self.assertEqual(deleted.status_code, 200)
        self.assertEqual(deleted.get_json()["sizeBytes"], 7)
        self.assertEqual(deleted.get_json()["fileCount"], 2)
        self.assertFalse(tree.exists())

    def test_protected_tree_must_be_unprotected_before_delete(self):
        self.claim()
        tree = self.seed_content_library("VKR")
        self.get("/api/depot/ownership")

        refused = self.delete(
            "/api/depot/entry",
            json={"path": "PROD/COMP/VKR", "confirm": "PROD/COMP/VKR"},
        )
        self.assertEqual(refused.status_code, 400)
        self.assertIn("unprotect", refused.get_json()["error"])
        self.assertTrue(tree.exists())

        upload = self.post(
            "/api/depot/upload",
            data={
                "path": "PROD/COMP/VKR",
                "upload": (io.BytesIO(b"blocked"), "blocked.bin"),
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(upload.status_code, 400)
        self.assertIn("unprotect", upload.get_json()["error"])
        self.assertFalse((tree / "blocked.bin").exists())

        self.post(
            "/api/depot/ownership", json={"name": "VKR", "protected": False}
        )
        deleted = self.delete(
            "/api/depot/entry",
            json={"path": "PROD/COMP/VKR", "confirm": "PROD/COMP/VKR"},
        )
        self.assertEqual(deleted.status_code, 200)
        self.assertFalse(tree.exists())

    def test_depot_mutations_refuse_sync_and_tool_update_locks(self):
        self.claim()
        victim = self.depot / "victim.bin"
        victim.write_bytes(b"victim")
        sync_lock_path = self.state_dir / "sync.lock"
        with sync_lock_path.open("a+") as sync_lock:
            fcntl.flock(sync_lock, fcntl.LOCK_EX)
            ownership = self.get("/api/depot/ownership")
            tree = self.get("/api/depot/tree")
            upload = self.post(
                "/api/depot/upload",
                data={
                    "path": "",
                    "upload": (io.BytesIO(b"new"), "new.bin"),
                },
                content_type="multipart/form-data",
            )
            delete = self.delete(
                "/api/depot/entry",
                json={"path": "victim.bin", "confirm": "victim.bin"},
            )
            self.assertEqual(upload.status_code, 409)
            self.assertEqual(delete.status_code, 409)
            self.assertEqual(ownership.status_code, 409)
            self.assertEqual(tree.status_code, 409)
            self.assertIn("running sync", upload.get_json()["error"])
            self.assertIn("running sync", ownership.get_json()["error"])
            self.assertTrue(victim.exists())
            fcntl.flock(sync_lock, fcntl.LOCK_UN)

        self.tool_store.mkdir(exist_ok=True)
        with (self.tool_store / ".update.lock").open("a+") as tool_lock:
            fcntl.flock(tool_lock, fcntl.LOCK_EX)
            refused = self.post(
                "/api/depot/upload",
                data={
                    "path": "",
                    "upload": (io.BytesIO(b"new"), "new.bin"),
                },
                content_type="multipart/form-data",
            )
            self.assertEqual(refused.status_code, 409)
            self.assertIn("tool update", refused.get_json()["error"])
            fcntl.flock(tool_lock, fcntl.LOCK_UN)

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
            self.settings.read_text()
            .replace('TZ="UTC"', 'TZ="Pacific/Kiritimati"')
            .replace('CRON_SCHEDULE="0 3 * * 0"', 'CRON_SCHEDULE="0 3 * * *"')
        )
        self.write_state(armed=False)
        (self.secrets / "activation-code.txt").write_text("secret\n")
        body = self.get("/api/status").get_json()
        next_run = datetime.fromisoformat(body["nextRun"])
        self.assertEqual(next_run.utcoffset(), timedelta(hours=14))
        self.assertTrue(body["armed"])

    def test_schedule_preview_uses_configured_timezone_and_validates(self):
        self.claim()
        preview = self.get(
            "/api/schedule/preview?cron=30+6+*+*+1,3&timezone=Pacific/Kiritimati"
        )
        self.assertEqual(preview.status_code, 200)
        body = preview.get_json()
        self.assertEqual(body["cron"], "30 6 * * 1,3")
        self.assertEqual(body["timezone"], "Pacific/Kiritimati")
        next_run = datetime.fromisoformat(body["nextRun"])
        self.assertEqual(next_run.utcoffset(), timedelta(hours=14))
        self.assertEqual((next_run.hour, next_run.minute), (6, 30))
        self.assertIn(next_run.isoweekday(), {1, 3})
        # An unsaved timezone edit previews in that zone rather than the stored one.
        override = self.get(
            "/api/schedule/preview?cron=0+3+*+*+*&timezone=America/Chicago"
        ).get_json()
        self.assertEqual(override["timezone"], "America/Chicago")
        self.assertIn(
            datetime.fromisoformat(override["nextRun"]).utcoffset(),
            {timedelta(hours=-5), timedelta(hours=-6)},
        )
        self.assertEqual(
            self.get("/api/schedule/preview?cron=0+3+*+*&timezone=UTC").status_code,
            400,
        )
        self.assertEqual(
            self.get("/api/schedule/preview?cron=0+99+*+*+*&timezone=UTC").status_code,
            400,
        )
        # A weekly picker with no weekday composes an empty day-of-week field.
        self.assertEqual(
            self.get("/api/schedule/preview?cron=30+6+*+*+&timezone=UTC").status_code,
            400,
        )
        self.assertEqual(
            self.get("/api/schedule/preview?cron=0+3+*+*+*&timezone=Mars/Olympus").status_code,
            400,
        )
        # A cleared or omitted timezone is what the save rejects, so the
        # preview rejects it too instead of falling back to the stored zone.
        self.assertEqual(
            self.get("/api/schedule/preview?cron=0+3+*+*+*&timezone=").status_code,
            400,
        )
        self.assertEqual(
            self.get("/api/schedule/preview?cron=0+3+*+*+*").status_code, 400
        )
        # Nothing is written by a preview.
        self.assertIn('CRON_SCHEDULE="0 3 * * 0"', self.settings.read_text())

    def test_schedule_preview_requires_owner(self):
        self.assertEqual(self.get("/api/schedule/preview?cron=0+3+*+*+*").status_code, 403)
        self.claim()
        self.post("/api/logout")
        self.assertEqual(self.get("/api/schedule/preview?cron=0+3+*+*+*").status_code, 401)

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

    @staticmethod
    def persistent_snapshot(root, ignored=()):
        if not root.exists():
            return {}
        ignored = set(ignored)
        snapshot = {".": (root.stat().st_mode & 0o777, None)}
        for path in sorted(root.rglob("*")):
            relative = str(path.relative_to(root))
            if relative in ignored:
                continue
            mode = path.stat().st_mode & 0o777
            snapshot[relative] = (mode, path.read_bytes() if path.is_file() else None)
        return snapshot

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
        self.assertEqual(module.SCHEMA_MARKER.read_text().strip(), "1")
        self.assertFalse(module.VERSION_STATUS.exists())
        self.assertFalse(module.MIGRATION_STATUS.exists())

    def test_matching_boot_repairs_fsgroup_bits_on_private_files(self):
        self.config.mkdir()
        (self.config / ".vcf-services-version").write_text("v0.2.1\n")
        self.secrets.mkdir()
        for consumer in ("redis", "sync", "sftp", "ui"):
            (self.secrets / consumer).mkdir()
        private_files = (
            "redis/redis-password",
            "redis/redis.conf",
            "sync/activation-code.txt",
            "sync/redis-password",
            "sftp/sftp-password",
            "ui/.credentials.lock",
            "ui/auth.json",
            "ui/flask-secret",
            "ui/redis-password",
        )
        for relative in private_files:
            path = self.secrets / relative
            path.write_text("preserved\n")
            path.chmod(0o660)

        self.run_bootstrap()

        for relative in private_files:
            path = self.secrets / relative
            self.assertEqual(path.read_text(), "preserved\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_existing_unmarked_config_is_backed_up_and_migrated(self):
        self.config.mkdir()
        settings = self.config / "settings.env"
        settings.write_text('SETUP_COMPLETE="true"\n')
        self.secrets.mkdir()
        (self.secrets / "restored-secret").write_text("preserve me\n")
        module = self.run_bootstrap()
        result = json.loads(module.MIGRATION_STATUS.read_text())
        self.assertEqual(result["fromSchema"], 0)
        self.assertEqual(result["toSchema"], 1)
        self.assertIsNone(result["fromVersion"])
        backup = Path(result["backupPath"])
        self.assertTrue(backup.is_relative_to(self.config))
        self.assertEqual((backup / "settings.env").read_text(), 'SETUP_COMPLETE="true"\n')
        migrated = settings.read_text()
        self.assertIn('SETUP_COMPLETE="true"', migrated)
        self.assertIn('DEPOT_ENDPOINT="dl.broadcom.com"', migrated)
        self.assertEqual(
            (self.secrets / "restored-secret").read_text(), "preserve me\n"
        )
        self.assertEqual(module.VERSION_MARKER.read_text().strip(), "v0.2.1")
        self.assertEqual(module.SCHEMA_MARKER.read_text().strip(), "1")
        self.assertFalse(module.VERSION_STATUS.exists())

    def test_older_marker_is_migrated_forward(self):
        self.config.mkdir()
        (self.config / ".vcf-services-version").write_text("v0.1.0\n")
        (self.config / "settings.env").write_text(
            'DEPOT_ENDPOINT="operator.example.test"\n'
        )
        module = self.run_bootstrap()
        result = json.loads(module.MIGRATION_STATUS.read_text())
        self.assertEqual(result["fromVersion"], "v0.1.0")
        self.assertEqual(result["toVersion"], "v0.2.1")
        self.assertIn(
            'DEPOT_ENDPOINT="operator.example.test"',
            (self.config / "settings.env").read_text(),
        )
        self.assertEqual(module.VERSION_MARKER.read_text().strip(), "v0.2.1")

    def test_same_schema_upgrade_backs_up_before_filling_defaults(self):
        self.config.mkdir()
        original = 'DEPOT_ENDPOINT="operator.example.test"\n'
        (self.config / "settings.env").write_text(original)
        (self.config / ".vcf-services-version").write_text("v0.2.0\n")
        (self.config / ".vcf-services-schema").write_text("1\n")
        (self.config / "software-depot-id").write_text("preserved-identity\n")
        module = self.run_bootstrap()
        result = json.loads(module.MIGRATION_STATUS.read_text())
        self.assertEqual(result["status"], "completed")
        self.assertEqual((result["fromSchema"], result["toSchema"]), (1, 1))
        self.assertEqual((result["fromVersion"], result["toVersion"]), ("v0.2.0", "v0.2.1"))
        backup = Path(result["backupPath"])
        self.assertEqual((backup / "settings.env").read_text(), original)
        self.assertEqual((backup / ".vcf-services-version").read_text(), "v0.2.0\n")
        self.assertEqual((backup / "software-depot-id").read_text(), "preserved-identity\n")
        self.assertEqual((self.config / "software-depot-id").read_text(), "preserved-identity\n")
        self.assertIn(original, module.SETTINGS.read_text())
        self.assertIn('TOKEN_URL="https://eapi.broadcom.com/vcf/generateToken"', module.SETTINGS.read_text())
        snapshot = self.persistent_snapshot(self.config)
        self.run_bootstrap()
        self.assertEqual(self.persistent_snapshot(self.config), snapshot)

    def test_interrupted_migration_keeps_old_marker_and_retries_with_report(self):
        self.config.mkdir()
        marker = self.config / ".vcf-services-version"
        report = self.config / ".vcf-services-migration.json"
        marker.write_text("v0.2.0\n")
        (self.config / ".vcf-services-schema").write_text("1\n")
        original = 'DEPOT_ENDPOINT="operator.example.test"\n'
        (self.config / "settings.env").write_text(original)
        replace = os.replace

        def interrupt_after_report(source, destination):
            replace(source, destination)
            if Path(destination) == report:
                raise KeyboardInterrupt("startup interrupted")

        with mock.patch.object(os, "replace", side_effect=interrupt_after_report):
            with self.assertRaises(KeyboardInterrupt):
                self.run_bootstrap()
        self.assertEqual(marker.read_text(), "v0.2.0\n")
        interrupted_result = json.loads(report.read_text())
        backup = Path(interrupted_result["backupPath"])
        self.assertEqual((backup / "settings.env").read_text(), original)
        module = self.run_bootstrap()
        result = json.loads(report.read_text())
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["fromVersion"], "v0.2.0")
        self.assertEqual(result["toVersion"], "v0.2.1")
        self.assertNotEqual(result["backupPath"], interrupted_result["backupPath"])
        self.assertEqual(marker.read_text(), "v0.2.1\n")
        self.assertFalse(module.VERSION_STATUS.exists())

    def test_unsupported_release_formats_block_without_migrating(self):
        module = self.run_bootstrap()
        for version in ("0.1.0", "v0.1.0-rc1", "v0.1.0+build", "v٠.١.٠"):
            with self.subTest(version=version):
                module.VERSION_MARKER.write_text(version + "\n")
                before = self.persistent_snapshot(self.config, {module.VERSION_STATUS.name})
                module.main()
                status = json.loads(module.VERSION_STATUS.read_text())
                self.assertTrue(status["blocked"])
                self.assertEqual(status["foundVersion"], version)
                self.assertEqual(
                    self.persistent_snapshot(self.config, {module.VERSION_STATUS.name}),
                    before,
                )

    def test_dev_sentinel_allows_upgrade_and_refuses_release_downgrade(self):
        module = self.run_bootstrap()
        with mock.patch.object(module, "CURRENT_VERSION", "dev"):
            module.main()
            self.assertEqual(module.VERSION_MARKER.read_text(), "dev\n")
            result = json.loads(module.MIGRATION_STATUS.read_text())
            self.assertEqual(result["toVersion"], "dev")
            self.assertFalse(module.VERSION_STATUS.exists())
        module.main()
        self.assertEqual(module.VERSION_MARKER.read_text(), "dev\n")
        self.assertTrue(json.loads(module.VERSION_STATUS.read_text())["blocked"])

    def test_newer_marker_is_quarantined_without_rewriting_state(self):
        self.config.mkdir()
        (self.config / ".vcf-services-version").write_text("v0.3.0\n")
        (self.config / ".vcf-services-schema").write_text("1\n")
        (self.config / "settings.env").write_text('SETUP_COMPLETE="true"\n')
        self.secrets.mkdir()
        (self.secrets / "restored-secret").write_text("preserve me\n")
        config_before = self.persistent_snapshot(self.config)
        secrets_before = self.persistent_snapshot(self.secrets)
        module = self.run_bootstrap()
        status = json.loads(module.VERSION_STATUS.read_text())
        self.assertEqual(status["expectedVersion"], "v0.2.1")
        self.assertEqual(status["foundVersion"], "v0.3.0")
        self.assertIn("newer", status["message"])
        self.assertEqual(
            self.persistent_snapshot(self.config, {module.VERSION_STATUS.name}),
            config_before,
        )
        self.assertEqual(self.persistent_snapshot(self.secrets), secrets_before)


if __name__ == "__main__":
    unittest.main()
