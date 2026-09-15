import json
import os
from pathlib import Path
import resource
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
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()

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
            "TMPDIR": str(self.scratch),
            "SETTINGS_FILE": str(self.root / "missing-settings"),
            "DEPOT_DIR": str(self.depot), "STATE_DIR": str(self.state),
            "AUTH_FILE": str(self.activation), "TOOL_ROOT": str(self.tool),
            "VCFDT_TOOL_STORE": str(self.tool), "REDIS_HOST": "",
            "DEPOT_OWNERSHIP_FILE": str(self.manifest),
            "DEPOT_OWNERSHIP_LOCK": str(self.state / "depot-ownership.lock"),
            "STUB_CALL_LOG": str(self.calls),
        }
        for key in ("STUB_LIST_COMPONENTS", "STUB_FAIL_TARGET", "STUB_FAIL_CATALOG_MODE",
                    "STUB_LIST_NO_TABLE", "STUB_LIST_RAW_ROWS", "STUB_WRITE_TREES",
                    "STUB_RETARGET_LINKS"):
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


# Every admitted run queries the three inventories in this order after its
# targets finish, so each expected call sequence ends with them.
CATALOG = ["binaries list install", "binaries list upgrade", "binaries list patch"]


class SyncProtectionScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.harness = Harness(self.temporary.name)

    def test_sync_builds_durable_catalog_from_all_supported_inventories(self):
        harness = self.harness
        extra = (
            "aaaaaaaa-0000-4000-8000-000000000001 | VCENTER | VMware vCenter | "
            "Server Appliance | 9.1.1.0.25000000 | 2026-07-01 | 2 GiB | UPGRADE"
        )

        result = harness.run("esx", env={"STUB_LIST_RAW_ROWS": extra})

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.called(), ["esx download"] + CATALOG)
        catalog = json.loads((harness.state / "catalog.json").read_text())
        attempt = json.loads((harness.state / "catalog-attempt.json").read_text())
        self.assertEqual(catalog["version"], 1)
        self.assertEqual(attempt["status"], "success")
        self.assertEqual(catalog["attemptId"], attempt["attemptId"])
        self.assertEqual({item["type"] for item in catalog["items"]},
                         {"INSTALL", "UPGRADE", "PATCH"})
        parsed = next(item for item in catalog["items"]
                      if item["id"] == "aaaaaaaa-0000-4000-8000-000000000001")
        self.assertEqual(parsed["component"], "VCENTER")
        self.assertEqual(parsed["name"], "VMware vCenter | Server Appliance")
        self.assertEqual(parsed["version"], "9.1.1.0.25000000")
        self.assertEqual(parsed["date"], "2026-07-01")
        self.assertEqual(parsed["size"], "2 GiB")
        self.assertEqual(parsed["type"], "UPGRADE")

    def test_catalog_failure_preserves_last_success_and_sync_result(self):
        harness = self.harness
        first = harness.run("esx")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        saved = (harness.state / "catalog.json").read_bytes()

        failed = harness.run("esx", env={"STUB_FAIL_CATALOG_MODE": "patch"})

        self.assertEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual((harness.state / "catalog.json").read_bytes(), saved)
        attempt = json.loads((harness.state / "catalog-attempt.json").read_text())
        self.assertEqual(attempt["status"], "failed")
        self.assertEqual(attempt["error"], "patch inventory query failed with exit code 23")
        self.assertIn("keeping the previous successful catalog", failed.stdout)

    def test_empty_inventory_keeps_the_last_catalog_and_records_the_outcome(self):
        harness = self.harness
        first = harness.run("esx")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        saved = (harness.state / "catalog.json").read_bytes()

        empty = harness.run("esx", env={"STUB_LIST_COMPONENTS": ""})

        self.assertEqual(empty.returncode, 0, empty.stdout + empty.stderr)
        self.assertEqual((harness.state / "catalog.json").read_bytes(), saved)
        attempt = json.loads((harness.state / "catalog-attempt.json").read_text())
        self.assertEqual(attempt["status"], "empty")
        self.assertNotIn("error", attempt)
        self.assertTrue(attempt["finishedAt"])
        self.assertIn("no components matched the current filter", empty.stdout)

    def test_first_empty_inventory_publishes_an_empty_catalog(self):
        harness = self.harness

        result = harness.run("esx", env={"STUB_LIST_COMPONENTS": ""})

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        catalog = json.loads((harness.state / "catalog.json").read_text())
        attempt = json.loads((harness.state / "catalog-attempt.json").read_text())
        self.assertEqual(catalog["items"], [])
        self.assertEqual(catalog["attemptId"], attempt["attemptId"])
        self.assertEqual(attempt["status"], "empty")
        self.assertTrue(catalog["updatedAt"])

    def test_catalog_workspace_is_cleared_when_a_run_is_terminated(self):
        # The workspace lives on the durable state volume, so a run stopped
        # between inventory queries must reap it through the exit path.
        harness = self.harness
        faults = harness.root / "catalog-term.bash"
        faults.write_text(
            'jq() {\n'
            '  if [ "${1:-}" = -Rn ]; then kill -TERM $$; fi\n'
            '  command jq "$@"\n'
            '}\n'
        )

        terminated = harness.run("esx", bash_env=faults)

        self.assertEqual(terminated.returncode, 143,
                         terminated.stdout + terminated.stderr)
        self.assertEqual(list(harness.state.glob("catalog-build.*")), [])
        attempt = json.loads((harness.state / "catalog-attempt.json").read_text())
        self.assertEqual(attempt["status"], "failed")
        self.assertIn("ended before catalog generation completed", attempt["error"])

    def test_interrupted_catalog_publish_cannot_replace_last_success(self):
        harness = self.harness
        first = harness.run("esx")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        saved = (harness.state / "catalog.json").read_bytes()
        faults = harness.root / "catalog-faults.bash"
        faults.write_text(
            'mv() {\n'
            '  case "$*" in *catalog.json.*) return 1 ;; esac\n'
            '  command mv "$@"\n'
            '}\n'
        )

        interrupted = harness.run("esx", bash_env=faults)

        self.assertEqual(interrupted.returncode, 0,
                         interrupted.stdout + interrupted.stderr)
        self.assertEqual((harness.state / "catalog.json").read_bytes(), saved)
        attempt = json.loads((harness.state / "catalog-attempt.json").read_text())
        self.assertEqual(attempt["status"], "failed")
        self.assertEqual(attempt["error"], "catalog could not be published")
        self.assertEqual(list(harness.state.glob("catalog.json.*")), [])

    def test_protected_partial_run_still_refreshes_catalog_without_changing_rc(self):
        harness = self.harness
        protected = harness.content_library("ESX_HOST")
        harness.protect("ESX_HOST")
        before = fingerprint(protected)

        result = harness.run("esx", "install")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(),
                         {"esx": "SKIPPED:PROTECTED", "install": "OK"})
        self.assertEqual(harness.called(),
                         ["binaries list install", "binaries download"] + CATALOG)
        self.assertEqual(
            {item["type"] for item in
             json.loads((harness.state / "catalog.json").read_text())["items"]},
            {"INSTALL", "UPGRADE", "PATCH"},
        )
        self.assertEqual(
            json.loads((harness.state / "catalog-attempt.json").read_text())["status"],
            "success",
        )
        self.assertEqual(fingerprint(protected), before)

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
        self.assertEqual(harness.called(), [
            "binaries list install", "binaries download",
            "binaries list upgrade", "binaries download",
            "binaries list patch", "binaries download",
        ] + CATALOG)
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
        self.assertEqual(harness.called(),
                         ["binaries list install", "binaries download",
                          "binaries list patch"] + CATALOG)
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
        self.assertEqual(harness.called(), ["binaries list patch"] + CATALOG)
        self.assertIn("PROD/COMP/VKR is protected and vcf-patches writes it", result.stdout)
        self.assertNotIn("SUPERVISOR is protected", result.stdout)

    def test_without_protected_trees_the_tool_is_not_asked_first(self):
        harness = self.harness
        harness.content_library("VKR")
        harness.protect(unprotected=("VKR",))

        result = harness.run("patches")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "OK"})
        self.assertEqual(harness.called(), ["binaries download"] + CATALOG)
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
                # The same fault stops the catalog after its first inventory.
                self.assertEqual(harness.called(),
                                 ["binaries list patch", "binaries list install"])
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
                self.assertEqual(harness.called(),
                                 ["binaries list patch", "binaries download"] + CATALOG)
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
        self.assertEqual(harness.called(),
                         ["binaries list patch", "binaries download"] + CATALOG)
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
        self.assertEqual(harness.called(), ["binaries list patch"] + CATALOG)
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
                # The malformed row stops the catalog after its first inventory.
                self.assertEqual(harness.called(),
                                 ["binaries list patch", "binaries list install"])
                self.assertIn("<<< vcf-patches FAILED:UNVERIFIED, continuing", result.stdout)
                self.assertEqual(fingerprint(vkr), before)
                self.assertEqual((vkr / "releases" / "v1" / "image.ova").read_bytes(), vkr_bytes)
                self.assertFalse((harness.depot / "STUB" / "patches").exists())

    def test_an_unreadable_entry_in_a_protected_tree_does_not_block_the_run(self):
        # An adopted library can hold a directory this user cannot read. The
        # run is not refused over it: find's error line becomes part of the
        # fingerprint, so it compares equal around the run, and the log names
        # the path so an operator can fix the permissions.
        if os.geteuid() == 0:
            self.skipTest("root can read every directory, so the case cannot be staged")
        harness = self.harness
        vkr = harness.content_library("VKR")
        harness.protect("VKR")
        closed = vkr / "releases" / "closed"
        closed.mkdir()
        (closed / "image.ova").write_bytes(b"operator bytes")
        os.chmod(closed, 0o000)
        self.addCleanup(os.chmod, closed, 0o755)
        before = fingerprint(vkr)

        result = harness.run("patches")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "OK"})
        self.assertEqual(harness.called(),
                         ["binaries list patch", "binaries download"] + CATALOG)
        self.assertEqual(result.stdout.count(
            "WARNING: find could not read some entries under protected tree PROD/COMP/VKR (1)"), 1)
        self.assertIn(str(closed), result.stdout)
        self.assertNotIn("FAILED", result.stdout)
        self.assertIn("<<< vcf-patches OK", result.stdout)
        self.assertEqual(fingerprint(vkr), before)
        self.assertEqual(list(harness.scratch.iterdir()), [])

    def test_an_after_run_fingerprint_that_cannot_be_taken_is_not_called_a_change(self):
        # Scratch space that fails while the after-run fingerprint is written
        # leaves the protected tree unverified, not modified: the operator is
        # never told a library changed on the strength of a missing snapshot.
        harness = self.harness
        vkr = harness.content_library("VKR")
        harness.protect("VKR")
        before = fingerprint(vkr)
        fault = harness.root / "fingerprint-fault.bash"
        fault.write_text(
            'function sort() {\n'
            '  local argument\n'
            '  for argument in "$@"; do\n'
            '    case "$argument" in\n'
            '      *.after.entries) return 1 ;;\n'
            '    esac\n'
            '  done\n'
            '  command sort "$@"\n}\n'
        )

        result = harness.run("patches", bash_env=fault)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "FAILED:UNVERIFIED"})
        self.assertEqual(harness.called(),
                         ["binaries list patch", "binaries download"] + CATALOG)
        self.assertIn("ERROR: could not take the after-run fingerprint of PROD/COMP/VKR after "
                      "vcf-patches ran, so the protected tree could not be verified", result.stdout)
        self.assertNotIn("changed while", result.stdout)
        self.assertIn("<<< vcf-patches FAILED:UNVERIFIED, continuing", result.stdout)
        self.assertEqual(fingerprint(vkr), before)
        self.assertEqual(list(harness.scratch.iterdir()), [])

    def test_a_large_protected_tree_is_checked_with_bounded_memory(self):
        # A protected library with tens of thousands of entries is
        # fingerprinted through temporary files and streaming comparisons, so
        # the shell never holds the listing: peak memory stays far below what
        # retaining every line would cost, a single unexpected entry among
        # them is still reported, and no scratch file outlives the run.
        harness = self.harness
        vkr = harness.content_library("VKR")
        for release in range(60):
            directory = vkr / "releases" / f"v{release:03d}"
            directory.mkdir(exist_ok=True)
            for index in range(1000):
                (directory / f"image{index:04d}.ova").touch()
        harness.protect("VKR")
        entries = sum(len(dirs) + len(files) for _, dirs, files in os.walk(vkr))
        self.assertGreater(entries, 60000)

        result = harness.run("patches")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "OK"})
        self.assertEqual(list(harness.scratch.iterdir()), [])
        peak_mib = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024
        self.assertLess(peak_mib, 64, f"peak child memory {peak_mib:.0f} MiB")

        result = harness.run("patches", env={"STUB_WRITE_TREES": "VKR"})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(harness.statuses(), {"patches": "FAILED:PROTECTED-CHANGED"})
        self.assertRegex(result.stdout, r"ERROR: protected tree PROD/COMP/VKR changed while "
                                        r"vcf-patches ran \(3 entries differ\)")
        self.assertIn("unexpected.bin", result.stdout)
        self.assertEqual(list(harness.scratch.iterdir()), [])

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
                expected_calls = {"healthy": "binaries list\nbinaries download\n"
                                             "binaries list\nbinaries list\nbinaries list\n",
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
