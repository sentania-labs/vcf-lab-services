import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).parents[1]
SCRIPT = PROJECT / "sync" / "sync.sh"
MAKE_STUB = PROJECT / "tests" / "make-stub-vcfdt.sh"


def fingerprint(tree):
    """Type, mode, owner, size, mtime, link count, inode, path and link target
    of every entry below the tree, without following links."""
    rows = []
    entries = [tree]
    for root, dirs, files in os.walk(tree):
        entries.extend(Path(root) / name for name in [*dirs, *files])
    for path in entries:
        meta = path.lstat()
        target = os.readlink(path) if path.is_symlink() else ""
        rows.append((str(path), meta.st_mode, meta.st_uid, meta.st_gid, meta.st_size,
                     meta.st_mtime_ns, meta.st_nlink, meta.st_ino, target))
    return sorted(rows)


class Harness:
    """A disposable depot, state volume and extracted stub tool."""

    def __init__(self, root):
        self.root = Path(root)
        self.depot = self.root / "depot"
        self.state = self.root / "state"
        self.tool = self.root / "tool"
        self.comp = self.depot / "PROD" / "COMP"
        for directory in (self.comp, self.state, self.tool):
            directory.mkdir(parents=True)
        archive = self.root / "vcf-download-tool-0.0.0-stub.tar.gz"
        subprocess.run([str(MAKE_STUB), str(archive)], check=True, capture_output=True)
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(self.tool), "--strip-components=1"],
                       check=True)
        (self.tool / ".update.lock").touch()
        self.activation = self.root / "activation"
        self.activation.write_text("test-activation\n")
        self.calls = self.root / "calls"
        self.manifest = self.state / "depot-ownership.json"

    def content_library(self, name):
        """An operator-provided tree with nested bytes, a symlink, and a
        distinctive mode and mtime, so any change to links or metadata shows in
        its fingerprint; the tests compare the fixture bytes separately."""
        tree = self.comp / name
        (tree / "releases" / "v1").mkdir(parents=True)
        (tree / "items.json").write_text("[]")
        (tree / "lib.json").write_text("{}")
        image = tree / "releases" / "v1" / "image.ova"
        image.write_bytes(b"operator bytes for " + name.encode())
        os.chmod(image, 0o640)
        os.utime(image, ns=(1_600_000_000_000_000_000, 1_600_000_000_000_000_000))
        (tree / "current").symlink_to("releases/v1")
        return tree

    def protect(self, *names, unprotected=()):
        trees = {name: {"ownership": "operator-provided", "protected": True} for name in names}
        trees.update({name: {"ownership": "operator-provided", "protected": False}
                      for name in unprotected})
        self.manifest.write_text(json.dumps({"version": 1, "trees": trees}))

    def run(self, *targets, env=None, bash_env=None):
        self.calls.write_text("")
        environment = {
            **os.environ,
            "HOME": str(self.root),
            "SETTINGS_FILE": str(self.root / "missing-settings"),
            "DEPOT_DIR": str(self.depot), "STATE_DIR": str(self.state),
            "AUTH_FILE": str(self.activation), "TOOL_ROOT": str(self.tool),
            "VCFDT_TOOL_STORE": str(self.tool), "REDIS_HOST": "",
            "DEPOT_OWNERSHIP_FILE": str(self.manifest),
            "DEPOT_OWNERSHIP_LOCK": str(self.state / "depot-ownership.lock"),
            "STUB_CALL_LOG": str(self.calls),
        }
        for key in ("STUB_LIST_COMPONENTS", "STUB_FAIL_TARGET", "STUB_LIST_NO_TABLE",
                    "STUB_LIST_RAW_ROWS", "STUB_WRITE_TREES", "STUB_RETARGET_LINKS"):
            environment.pop(key, None)
        environment.update(env or {})
        if bash_env:
            environment["BASH_ENV"] = str(bash_env)
        result = subprocess.run(["bash", str(SCRIPT), *targets], env=environment,
                                capture_output=True, text=True, timeout=60)
        return result

    def statuses(self):
        recorded = json.loads((self.state / "state.json").read_text())["lastRun"]
        return {target: entry["status"] for target, entry in recorded.items()}

    def called(self):
        return self.calls.read_text().splitlines()


class SyncProtectionScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.harness = Harness(self.temporary.name)

    def test_unrelated_downloads_run_while_content_libraries_stay_protected(self):
        # Issue #47: VKR and SUPERVISOR are protected operator libraries. The
        # tool's own listing for each binaries target names other trees, so
        # the downloads run and the protected trees are metadata and link
        # identical afterwards by fingerprint, with their bytes compared
        # directly.
        harness = self.harness
        vkr = harness.content_library("VKR")
        supervisor = harness.content_library("SUPERVISOR")
        harness.protect("VKR", "SUPERVISOR")
        before = {"VKR": fingerprint(vkr), "SUPERVISOR": fingerprint(supervisor)}
        files = ["items.json", "lib.json", "releases/v1/image.ova"]
        bytes_before = {tree / name: (tree / name).read_bytes()
                        for tree in (vkr, supervisor) for name in files}

        result = harness.run("install", "upgrade", "patches")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(),
                         {"install": "OK", "upgrade": "OK", "patches": "OK"})
        self.assertEqual(harness.called(), ["binaries list", "binaries download"] * 3)
        self.assertEqual(fingerprint(vkr), before["VKR"])
        self.assertEqual(fingerprint(supervisor), before["SUPERVISOR"])
        self.assertEqual({path: path.read_bytes() for path in bytes_before}, bytes_before)
        self.assertIn("vcf-install writes 3 trees under PROD/COMP (NSX_T_MANAGER, "
                      "SDDC_MANAGER_VCF, VCENTER); none of them is protected", result.stdout)
        self.assertIn("vcf-patches writes 4 trees under PROD/COMP (ESX_HOST, NSX_T_MANAGER, "
                      "VCENTER, VCFDT); none of them is protected", result.stdout)
        self.assertNotIn("is protected and", result.stdout)
        self.assertNotIn("SKIPPED", result.stdout)
        self.assertNotIn("ERROR", result.stdout)
        for target in ("install", "upgrade", "patches"):
            self.assertTrue((harness.depot / "STUB" / target / "20000000.bin").exists())
            self.assertTrue((harness.comp / "VCENTER" / f"stub-{target}.bin").exists())
        self.assertIn("<<< vcf-patches OK", result.stdout)
        self.assertIn("sync finished overall rc=0", result.stdout)

    def test_a_target_that_lists_a_protected_tree_is_a_genuine_conflict(self):
        # ESX_HOST protected: the ESX image library is a single-tree command
        # aimed at it, and the patches listing names it, so both skip and say
        # which tree conflicts. The install listing does not name it, so
        # install runs. The protected tree is unchanged throughout.
        harness = self.harness
        esx_host = harness.content_library("ESX_HOST")
        harness.protect("ESX_HOST")
        before = fingerprint(esx_host)

        result = harness.run("esx", "install", "patches")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {
            "esx": "SKIPPED:PROTECTED", "install": "OK", "patches": "SKIPPED:PROTECTED"})
        self.assertEqual(harness.called(), ["binaries list", "binaries download", "binaries list"])
        self.assertIn("PROD/COMP/ESX_HOST is protected and esx-image-library writes it, "
                      "skipping the target without changing it", result.stdout)
        self.assertIn("PROD/COMP/ESX_HOST is protected and vcf-patches writes it, "
                      "skipping the target without changing it", result.stdout)
        self.assertIn("<<< vcf-patches SKIPPED:PROTECTED", result.stdout)
        self.assertIn("<<< vcf-install OK", result.stdout)
        self.assertEqual(fingerprint(esx_host), before)
        self.assertTrue((harness.depot / "STUB" / "install").exists())
        self.assertFalse((harness.depot / "STUB" / "patches").exists())
        self.assertFalse((harness.depot / "STUB" / "esx").exists())

    def test_only_the_conflicting_tree_is_named(self):
        harness = self.harness
        harness.content_library("VKR")
        harness.content_library("SUPERVISOR")
        harness.protect("VKR", "SUPERVISOR")

        result = harness.run("patches", env={"STUB_LIST_COMPONENTS": "VCENTER VKR"})

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "SKIPPED:PROTECTED"})
        self.assertEqual(harness.called(), ["binaries list"])
        self.assertIn("PROD/COMP/VKR is protected and vcf-patches writes it", result.stdout)
        self.assertNotIn("SUPERVISOR is protected", result.stdout)

    def test_without_protected_trees_the_tool_is_not_asked_first(self):
        harness = self.harness
        harness.content_library("VKR")
        harness.protect(unprotected=("VKR",))

        result = harness.run("patches")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "OK"})
        self.assertEqual(harness.called(), ["binaries download"])
        self.assertNotIn("writes", result.stdout)

    def test_unprovable_scope_does_not_run_and_leaves_protected_trees(self):
        harness = self.harness
        vkr = harness.content_library("VKR")
        harness.protect("VKR")
        before = fingerprint(vkr)
        cases = (
            ({"STUB_FAIL_TARGET": "list"}, 23, "FAILED:23",
             "the tool could not list the binaries this target would download (exit 23)"),
            ({"STUB_LIST_NO_TABLE": "1"}, 1, "FAILED:UNVERIFIED",
             "the tool listing has no component table"),
        )
        for env, code, status, message in cases:
            with self.subTest(status=status):
                result = harness.run("patches", env=env)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertEqual(harness.statuses(), {"patches": status})
                self.assertEqual(harness.called(), ["binaries list"])
                self.assertIn(f"ERROR: {message}", result.stdout)
                self.assertIn("what vcf-patches would write is not proven, so the target is not run",
                              result.stdout)
                self.assertIn(f"<<< vcf-patches {status}, continuing", result.stdout)
                self.assertEqual(fingerprint(vkr), before)
                self.assertFalse((harness.depot / "STUB" / "patches").exists())

    def test_a_change_inside_a_protected_tree_during_the_run_is_reported(self):
        # A tool that writes outside what it listed, or re-points a link, is
        # caught by the fingerprint taken around the run: the target is not
        # reported as a clean download and the run exits nonzero.
        harness = self.harness
        vkr = harness.content_library("VKR")
        supervisor = harness.content_library("SUPERVISOR")
        harness.protect("VKR", "SUPERVISOR")
        cases = (
            ({"STUB_WRITE_TREES": "VKR"}, "VKR", "SUPERVISOR", supervisor),
            ({"STUB_RETARGET_LINKS": "SUPERVISOR"}, "SUPERVISOR", "VKR", vkr),
        )
        for env, changed, untouched, untouched_tree in cases:
            with self.subTest(changed=changed):
                before = fingerprint(untouched_tree)
                result = harness.run("patches", env=env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(harness.statuses(), {"patches": "FAILED:PROTECTED-CHANGED"})
                self.assertEqual(harness.called(), ["binaries list", "binaries download"])
                self.assertRegex(result.stdout,
                                 rf"ERROR: protected tree PROD/COMP/{changed} changed while "
                                 r"vcf-patches ran \([0-9]+ entries differ\)")
                self.assertNotIn(f"PROD/COMP/{untouched} changed", result.stdout)
                self.assertIn("<<< vcf-patches FAILED:PROTECTED-CHANGED, continuing", result.stdout)
                self.assertEqual(fingerprint(untouched_tree), before)
        # A misbehaving tool that also fails keeps its own exit code, and the
        # recorded status still says a protected tree changed.
        result = harness.run("patches", env={"STUB_WRITE_TREES": "VKR", "STUB_FAIL_TARGET": "patches"})
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "FAILED:PROTECTED-CHANGED"})
        self.assertEqual(harness.called(), ["binaries list", "binaries download"])
        self.assertRegex(result.stdout, r"ERROR: protected tree PROD/COMP/VKR changed while vcf-patches ran")
        self.assertIn("<<< vcf-patches FAILED:PROTECTED-CHANGED (tool rc=23), continuing", result.stdout)

    def test_a_full_name_containing_the_delimiter_still_names_its_component(self):
        harness = self.harness
        vkr = harness.content_library("VKR")
        harness.protect("VKR")
        before = fingerprint(vkr)
        row = ("0000000f-0000-4000-8000-000000000015 | VKR | Kubernetes | Releases | "
               "9.1.0.0.20000000 | 2026-01-01 | 1 KiB | PATCH")

        result = harness.run("patches", env={"STUB_LIST_RAW_ROWS": row})

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "SKIPPED:PROTECTED"})
        self.assertEqual(harness.called(), ["binaries list"])
        self.assertIn("PROD/COMP/VKR is protected and vcf-patches writes it", result.stdout)
        self.assertEqual(fingerprint(vkr), before)

    def test_an_unreadable_listing_row_leaves_the_target_unrun(self):
        harness = self.harness
        vkr = harness.content_library("VKR")
        harness.protect("VKR")
        before = fingerprint(vkr)
        vkr_bytes = (vkr / "releases" / "v1" / "image.ova").read_bytes()
        rows = {
            "fewer cells": "0000000f-0000-4000-8000-000000000015 | VKR | Kubernetes Releases",
            "empty component": ("0000000f-0000-4000-8000-000000000015 |  | Kubernetes Releases | "
                                "9.1.0.0.20000000 | 2026-01-01 | 1 KiB | PATCH"),
        }
        for case, row in rows.items():
            with self.subTest(case=case):
                result = harness.run("patches", env={"STUB_LIST_RAW_ROWS": row})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(harness.statuses(), {"patches": "FAILED:UNVERIFIED"})
                self.assertEqual(harness.called(), ["binaries list"])
                self.assertIn("<<< vcf-patches FAILED:UNVERIFIED, continuing", result.stdout)
                self.assertEqual(fingerprint(vkr), before)
                self.assertEqual((vkr / "releases" / "v1" / "image.ova").read_bytes(), vkr_bytes)
                self.assertFalse((harness.depot / "STUB" / "patches").exists())

    def test_vkr_target_respects_its_own_tree(self):
        harness = self.harness
        vkr = harness.content_library("VKR")
        supervisor = harness.content_library("SUPERVISOR")
        harness.protect("VKR", "SUPERVISOR")
        mirror = harness.root / "vkr.bash"
        mirror.write_text(
            'function /usr/local/lib/vcf-services/targets/vkr.sh() {\n'
            '  printf "mirrored\\n" > "$1/PROD/COMP/VKR/content.txt"\n}\n'
        )
        before = fingerprint(vkr)

        result = harness.run("vkr", bash_env=mirror)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"vkr": "SKIPPED:PROTECTED"})
        self.assertIn("PROD/COMP/VKR is protected and vkr-content-library writes it", result.stdout)
        self.assertEqual(fingerprint(vkr), before)

        harness.protect("SUPERVISOR", unprotected=("VKR",))
        before_supervisor = fingerprint(supervisor)
        result = harness.run("vkr", bash_env=mirror)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"vkr": "OK"})
        self.assertEqual((vkr / "content.txt").read_text(), "mirrored\n")
        self.assertEqual(fingerprint(supervisor), before_supervisor)


class SyncOwnershipFailureTests(unittest.TestCase):
    def test_ownership_failures_stop_sync_and_preserve_manifest(self):
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
                    '#!/bin/bash\nprintf "%s %s\\n" "$1" "$2" >> "$CALL_LOG"\n'
                    'if [ "$2" = list ]; then\n'
                    '  echo "ID | Component | Component Full Name | Version | Release Date | Size | Type"\n'
                    '  echo "00000001-0000-4000-8000-000000000001 | VCENTER | vCenter | 9.1 | 2026-01-01 | 1 KiB | INSTALL"\n'
                    '  exit 0\nfi\n'
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
                    ["bash", str(SCRIPT), "esx", "install"], env=environment,
                    capture_output=True, text=True, timeout=20,
                )
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0 if failure == "healthy" else 1, output)
                # With ESX_HOST protected the healthy run skips esx and asks the
                # tool what install writes before downloading; the post-dispatch
                # fault has no protected tree, so esx runs and creates the tree
                # whose recording then fails.
                expected_calls = {"healthy": "binaries list\nbinaries download\n",
                                  "post-dispatch": "esx download\n"}
                self.assertEqual(calls.read_text() if calls.exists() else "",
                                 expected_calls.get(failure, ""))
                if failure == "healthy":
                    entry = json.loads(manifest.read_text())["trees"]["ESX_HOST"]
                    self.assertEqual(entry, {"ownership": "operator-provided", "protected": True})
                    self.assertIn("PROD/COMP/ESX_HOST is protected and esx-image-library writes it, "
                                  "skipping", output)
                    self.assertIn("<<< vcf-install OK", output)
                else:
                    self.assertIn("refusing sync", output)
                    if original is None:
                        self.assertFalse(manifest.exists())
                    else:
                        self.assertEqual(manifest.read_text(), original)
                if (tree / "operator.bin").exists():
                    self.assertEqual((tree / "operator.bin").read_bytes(), b"operator")
                self.assertEqual(list(state.glob("depot-ownership.json.*")), [])


if __name__ == "__main__":
    unittest.main()
