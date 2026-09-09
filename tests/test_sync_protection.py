import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SyncProtectionTests(unittest.TestCase):
    def test_ownership_failures_stop_sync_and_preserve_manifest(self):
        script = Path(__file__).parents[1] / "sync" / "sync.sh"
        cases = (
            "create-write", "update-write", "rename", "temporary-file", "lock",
            "invalid-json", "empty-manifest", "read", "post-dispatch", "healthy",
        )
        for failure in cases:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                depot, state, tool = (root / name for name in ("depot", "state", "tool"))
                for directory in (depot, state, tool / "bin"):
                    directory.mkdir(parents=True)
                tree = depot / "PROD" / "COMP" / "ESX_HOST"
                if failure not in ("read", "post-dispatch"):
                    tree.mkdir(parents=True)
                    (tree / "items.json").write_text("[]")
                    (tree / "lib.json").write_text("{}")
                    (tree / "operator.bin").write_bytes(b"operator")
                manifest = state / "depot-ownership.json"
                original = None
                if failure == "empty-manifest":
                    original = ""
                elif failure in ("invalid-json", "read"):
                    original = "{broken"
                elif failure != "create-write":
                    original = json.dumps({"version": 1, "trees": {
                        "OTHER": {"ownership": "operator-provided", "protected": False}
                    }})
                if original is not None:
                    manifest.write_text(original)
                lock = state / "depot-ownership.lock"
                if failure == "lock":
                    lock.mkdir()
                (tool / ".update.lock").touch()
                executable = tool / "bin" / "vcf-download-tool"
                executable.write_text(
                    '#!/bin/bash\nprintf "invoked\\n" >> "$CALL_LOG"\n'
                    'if [ "$OWNERSHIP_FAULT" = post-dispatch ]; then\n'
                    '  mkdir -p "$DEPOT_DIR/PROD/COMP/NEW"\nfi\n'
                )
                executable.chmod(0o755)
                activation = root / "activation"
                activation.write_text("test-activation")
                faults = root / "faults.bash"
                faults.write_text(
                    'jq() {\n'
                    '  case "$OWNERSHIP_FAULT:$*" in\n'
                    '    create-write:*"--arg name"*|update-write:*"--arg name"*|'
                    'post-dispatch:*"--arg name"*)\n'
                    '      printf "partial write"; return 1 ;;\n'
                    '  esac\n'
                    '  command jq "$@"\n}\n'
                    'mktemp() {\n'
                    '  case "$OWNERSHIP_FAULT:$*" in\n'
                    '    temporary-file:*depot-ownership.json*) return 1 ;;\n'
                    '  esac\n'
                    '  command mktemp "$@"\n}\n'
                    'mv() {\n'
                    '  case "$OWNERSHIP_FAULT:$*" in\n'
                    '    rename:*depot-ownership.json*) return 1 ;;\n'
                    '  esac\n'
                    '  command mv "$@"\n}\n'
                )
                calls = root / "calls"
                environment = {
                    **os.environ,
                    "SETTINGS_FILE": str(root / "missing-settings"),
                    "DEPOT_DIR": str(depot), "STATE_DIR": str(state),
                    "AUTH_FILE": str(activation), "TOOL_ROOT": str(tool),
                    "VCFDT_TOOL_STORE": str(tool), "REDIS_HOST": "",
                    "DEPOT_OWNERSHIP_FILE": str(manifest),
                    "DEPOT_OWNERSHIP_LOCK": str(lock),
                    "BASH_ENV": str(faults), "CALL_LOG": str(calls),
                    "OWNERSHIP_FAULT": failure,
                }
                result = subprocess.run(
                    ["bash", str(script), "esx", "install"], env=environment,
                    capture_output=True, text=True, timeout=20,
                )
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0 if failure == "healthy" else 1, output)
                self.assertEqual(calls.read_text() if calls.exists() else "",
                                 "invoked\n" if failure == "post-dispatch" else "")
                if failure == "healthy":
                    entry = json.loads(manifest.read_text())["trees"]["ESX_HOST"]
                    self.assertEqual(entry, {"ownership": "operator-provided", "protected": True})
                    self.assertIn("is protected, skipping", output)
                else:
                    self.assertIn("refusing sync", output)
                    if original is None:
                        self.assertFalse(manifest.exists())
                    else:
                        self.assertEqual(manifest.read_text(), original)
                if (tree / "operator.bin").exists():
                    self.assertEqual((tree / "operator.bin").read_bytes(), b"operator")
                self.assertEqual(list(state.glob("depot-ownership.json.*")), [])

    def test_protection_prevents_dispatch_and_unprotect_restores_it(self):
        script = Path(__file__).parents[1] / "sync" / "sync.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            depot = root / "depot"
            state = root / "state"
            tool = root / "tool"
            for directory in (depot, state, tool / "bin"):
                directory.mkdir(parents=True)
            (tool / ".update.lock").touch()
            executable = tool / "bin" / "vcf-download-tool"
            executable.write_text('#!/bin/bash\nprintf "invoked\\n" >> "$CALL_LOG"\n')
            executable.chmod(0o755)
            activation = root / "activation"
            activation.write_text("test-activation")
            bash_env = root / "targets.bash"
            bash_env.write_text(
                'function /usr/local/lib/vcf-services/targets/vkr.sh() {\n'
                '  printf "invoked\\n" >> "$CALL_LOG"\n}\n'
            )
            calls = root / "calls"
            environment = {
                **os.environ,
                "SETTINGS_FILE": str(root / "missing-settings"),
                "DEPOT_DIR": str(depot), "STATE_DIR": str(state),
                "AUTH_FILE": str(activation), "TOOL_ROOT": str(tool),
                "VCFDT_TOOL_STORE": str(tool), "REDIS_HOST": "",
                "DEPOT_OWNERSHIP_FILE": str(state / "depot-ownership.json"),
                "DEPOT_OWNERSHIP_LOCK": str(state / "depot-ownership.lock"),
                "BASH_ENV": str(bash_env), "CALL_LOG": str(calls),
            }
            cases = [(target, "ESX_HOST") for target in ("esx", "install", "upgrade", "patches")]
            cases += [(target, "NSX") for target in ("install", "upgrade", "patches")]
            cases += [("vkr", "VKR")]
            for target, name in cases:
                with self.subTest(target=target, tree=name):
                    tree = depot / "PROD" / "COMP" / name
                    tree.mkdir(parents=True, exist_ok=True)
                    sentinel = tree / "operator.bin"
                    sentinel.write_bytes(b"operator")
                    for protected in (True, False):
                        manifest = {"version": 1, "trees": {
                            name: {"ownership": "operator-provided", "protected": protected}
                        }}
                        (state / "depot-ownership.json").write_text(json.dumps(manifest))
                        calls.write_text("")
                        result = subprocess.run(
                            ["bash", str(script), target], env=environment,
                            capture_output=True, text=True, timeout=20,
                        )
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        recorded = json.loads((state / "state.json").read_text())
                        self.assertEqual(recorded["lastRun"][target]["status"],
                                         "SKIPPED:PROTECTED" if protected else "OK")
                        self.assertEqual(calls.read_text(), "" if protected else "invoked\n")
                        self.assertEqual(sentinel.read_bytes(), b"operator")
                        if protected:
                            self.assertIn(f"PROD/COMP/{name} is protected, skipping", result.stdout)


if __name__ == "__main__":
    unittest.main()
