import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SyncProtectionTests(unittest.TestCase):
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
