import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).with_name("fixtures") / "pr_annotations"
REPORT = FIXTURES / "completed.json"
MANIFEST = FIXTURES / "trusted-completed.json"
sys.path.insert(0, str(SCRIPTS))
import pr_annotations as generate


class AnnotationTests(unittest.TestCase):
    def setUp(self):
        self.raw = REPORT.read_bytes()
        self.report = json.loads(self.raw)
        self.manifest = json.loads(MANIFEST.read_bytes())

    def attest_test_bytes(self, raw=None):
        # Refresh only the transport digest for semantic corruption tests.
        # Keep the independently supplied expectations from the fixture.
        if raw is None:
            raw = json.dumps(self.report).encode()
        self.manifest["report_sha256"] = hashlib.sha256(raw).hexdigest()
        return raw

    def assert_invalid_report(self, message):
        with self.assertRaisesRegex(ValueError, message):
            generate.annotations(self.attest_test_bytes(), self.manifest, 10)

    @staticmethod
    def cli(report, manifest, cap):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPTS / "pr_annotations.py"),
             "--report", str(report), "--manifest", str(manifest), "--annotation-cap", str(cap)],
            capture_output=True, check=False, text=True,
        )

    def test_completed_fixture_and_deterministic_cli(self):
        result = self.cli(REPORT, MANIFEST, 10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.cli(REPORT, MANIFEST, 10).stdout, result.stdout)
        data = json.loads(result.stdout)
        self.assertEqual(data["run_id"], "turtles-run-fixture")
        self.assertEqual(data["selection"]["scope"], "diff")
        self.assertEqual(data["selection"]["classified"], 4)
        self.assertEqual(data["summary"], dict(annotation_cap=10, eligible=2,
                                                emitted=2, omitted=0, truncated=False))
        survivor, timeout = data["annotations"]
        self.assertEqual(survivor["path"], "example/calc.mbt")
        self.assertEqual((survivor["start_line"], survivor["end_line"]), (2, 2))
        self.assertEqual(survivor["mutant_id"], "m-c742f68b57434bd4")
        self.assertEqual(survivor["evidence"], dict(outcome="SURVIVED", group="arithmetic",
                                                    original="+", replacement="-"))
        self.assertEqual(survivor["rerun"], dict(
            strategy="repeat-original-invocation-and-locate-id", mutant_id=survivor["mutant_id"]))
        self.assertEqual(timeout["start_line"], 4)
        self.assertEqual(timeout["evidence"]["outcome"], "TIMEOUT")
        self.assertIn("timeout", timeout["message"])

    def test_cap_counts_and_order(self):
        for cap in (0, 1, 2):
            with self.subTest(cap=cap):
                payload = generate.annotations(self.raw, self.manifest, cap)
                self.assertEqual([item["start_line"] for item in payload["annotations"]],
                                 [2, 4][:cap])
                self.assertEqual(payload["summary"], dict(annotation_cap=cap, eligible=2,
                                                           emitted=cap, omitted=2-cap,
                                                           truncated=cap < 2))
        for cap in (True, -1, 2**31):
            with self.subTest(invalid_cap=cap), self.assertRaisesRegex(ValueError, "cap"):
                generate.annotations(self.raw, self.manifest, cap)

    def test_authentic_artifact_bytes_required(self):
        with self.assertRaisesRegex(ValueError, "report SHA-256"):
            generate.annotations(self.raw + b" ", self.manifest, 5)

    def test_stale_run_source_and_selection(self):
        changes = (
            ("run_id", "different-current-run", "run_id"),
            ("module", "/work/other/example", "module"),
            ("target", "wasm", "target"),
            ("test_scope", "affected", "test_scope"),
            ("files", {**self.manifest["files"], "calc_test.mbt": "0" * 16}, "source fingerprints"),
            ("selection", {**self.manifest["selection"],
                           "diff": {**self.manifest["selection"]["diff"], "fingerprint": "0" * 16}},
             "selection metadata"),
            ("selection", {**self.manifest["selection"], "discovered": 8, "diff_excluded": 3},
             "selection metadata"),
            ("selected_lines", {**self.manifest["selected_lines"], "m-c742f68b57434bd4": 3},
             "selected mutant IDs or lines"),
        )
        for field, expected, message in changes:
            with self.subTest(field=field, message=message), self.assertRaisesRegex(ValueError, message):
                generate.annotations(self.raw, {**self.manifest, field: expected}, 5)
        for field in ("run_id", "module", "files", "selection", "selected_lines", "target",
                      "test_scope", "report_sha256", "exit_code", "module_prefix"):
            with self.subTest(missing=field), self.assertRaises(ValueError):
                manifest = self.manifest.copy()
                del manifest[field]
                generate.annotations(self.raw, manifest, 5)

    def test_failed_invocation_cannot_reuse_completed_report(self):
        result = self.cli(REPORT, FIXTURES / "trusted-setup-failure.json", 5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("current invocation did not complete", result.stderr)
        for exit_code in (2, -15, 124, None, True):
            with self.subTest(exit_code=exit_code), self.assertRaises(ValueError):
                generate.annotations(self.raw, {**self.manifest, "exit_code": exit_code}, 5)

    def test_noncompleted_report_states(self):
        for state in ("partial", "setup_error", "unknown", "cancelled", None):
            with self.subTest(state=state):
                self.report["execution"] = state
                self.assert_invalid_report("completed schema-4")
        self.report["execution"] = "completed"
        self.report["diagnostics"] = {"error": "baseline"}
        self.assert_invalid_report("completed schema-4")

    def test_configured_sharded_and_incomplete_selection(self):
        for edits, message in (
            ({"scope": "configured", "diff": None, "diff_excluded": 0}, "diff scope"),
            ({"shard": {"index": 0}}, "shard"),
            ({"classified": 3}, "selection counts"),
            ({"discovered": 90}, "selection counts"),
        ):
            with self.subTest(edits=edits):
                self.report = json.loads(self.raw)
                self.report["selection"].update(edits)
                self.assert_invalid_report(message)
        self.report = json.loads(self.raw)
        self.report["skipped_files"] = [{"path": "a.mbt", "error": "parser failed"}]
        self.assert_invalid_report("incomplete source discovery")

    def test_posix_punctuation_in_module_prefix_and_unselected_files(self):
        self.manifest["module_prefix"] = 'examples/demo./set: "a" <b>|*? '
        self.report["files"]["scratch?/helper.mbt"] = "0" * 16
        self.manifest["files"]["scratch?/helper.mbt"] = "0" * 16
        output = generate.annotations(self.attest_test_bytes(), self.manifest, 1)
        path = json.loads(json.dumps(output))["annotations"][0]["path"]
        self.assertEqual(path, 'examples/demo./set: "a" <b>|*? /calc.mbt')

    def test_unsafe_paths_in_report_and_manifest(self):
        unsafe = ("../calc.mbt", "dir/../../calc.mbt", "/calc.mbt", "C:/calc.mbt",
                  "C:calc.mbt", r"dir\calc.mbt", "//server/calc.mbt", "dir//calc.mbt",
                  r"\\server\calc.mbt", "dir/", ".", "..",
                  "./calc.mbt", "dir/./calc.mbt", "dir/.Git/calc.mbt", "dir/calc.mbt\x00",
                  "dir/calc\n.mbt", "dir/calc\x7f.mbt", "dir/calc\x85.mbt", "x\u202e.mbt")
        for path in unsafe:
            with self.subTest(path=path):
                self.report["mutants"][0]["path"] = path
                self.assert_invalid_report("source path")
                with self.assertRaisesRegex(ValueError, "source path"):
                    generate.annotations(self.raw, {**self.manifest, "module_prefix": path}, 5)
        self.report = json.loads(self.raw)
        self.report["files"]["../extra.mbt"] = "0" * 16
        self.assert_invalid_report("source path")

    def test_every_row_validated_even_with_zero_cap(self):
        for field, value, message in (
            ("line", 0, "line"), ("line", -1, "line"), ("line", 2**31, "line"),
            ("line", 200, "selected mutant IDs or lines"), ("line", 1.0, "line"),
            ("line", True, "line"), ("id", "m-bad", "mutant ID"),
            ("id", "m-0000000000000000", "reported identity"),
            ("outcome", "SKIPPED", "outcome"), ("outcome", [], "outcome"),
        ):
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, message):
                self.report = json.loads(self.raw)
                self.report["mutants"][0][field] = value
                generate.annotations(self.attest_test_bytes(), self.manifest, 0)

    def test_duplicates_and_counts(self):
        for change, message in (
            (lambda report: report["mutants"].__setitem__(0, report["mutants"][1]), "duplicate mutant ID"),
            (lambda report: report["mutants"].pop(), "row count"),
            (lambda report: report["summary"].update(timeout=0), "timeout count"),
            (lambda report: report["summary"].update(score=True), "mutation score"),
            (lambda report: report["summary"].update(survived=True), "survived count"),
            (lambda report: report["selection"].update(target_inactive=True), "target_inactive count"),
            (lambda report: report.update(inactive_mutants=True), "inactive_mutants count"),
            (lambda report: report["summary"]["kills_by_kind"].update(property=1), "kill attribution count"),
            (lambda report: report["summary"]["score_public"].update(mutants=False), "visibility mutant count"),
        ):
            with self.subTest(message=message):
                self.report = json.loads(self.raw)
                change(self.report)
                self.assert_invalid_report(message)

    def test_zero_selection_does_not_create_annotations(self):
        self.report["mutants"] = []
        self.report["selection"].update(selected=0, classified=0, discovered=3)
        self.manifest["selection"] = self.report["selection"].copy()
        self.manifest["selected_lines"] = {}
        self.report["summary"].update(killed=0, survived=0, timeout=0, unviable=0, score=100)
        self.report["summary"]["score_public"] = self.report["summary"]["score_private"].copy()
        payload = generate.annotations(self.attest_test_bytes(), self.manifest, 5)
        self.assertEqual(payload["annotations"], [])
        self.assertEqual(payload["selection"]["selected"], 0)
        self.assertEqual(payload["selection"]["scope"], "diff")
        self.assertFalse(payload["summary"]["truncated"])

    def test_default_target_omission_and_attributed_kill(self):
        del self.report["target"]
        self.manifest["target"] = None
        self.report["inactive_mutants"] = 0
        self.report["inactive_files"] = []
        self.report["selection"].update(discovered=6, target_inactive=0)
        self.manifest["selection"] = self.report["selection"].copy()
        killed = next(row for row in self.report["mutants"] if row["outcome"] == "KILLED")
        del killed["attribution"]
        killed["killed_by"] = [{"package": "example/d4", "filename": "calc_test.mbt",
                                "index": 0, "test_name": "property", "kind": "Property",
                                "counterexample": "0"}]
        self.report["summary"]["kills_by_kind"]["property"] = 1
        self.report["summary"]["property_only_kills"] = 1
        payload = generate.annotations(self.attest_test_bytes(), self.manifest, 10)
        self.assertIsNone(payload["target"])
        self.assertEqual(payload["summary"]["eligible"], 2)

    def test_cli_errors_keep_stdout_empty(self):
        bad_inputs = (
            b'{"schema":4',
            b'{"schema":4,"schema":3}',
            b'{"score":NaN}',
            b'[]',
            self.raw.replace(b'"SURVIVED"', b'"::error::untrusted"'),
        )
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "report.json"
            manifest = Path(tmp) / "manifest.json"
            for raw in bad_inputs:
                with self.subTest(raw=raw[:30]):
                    report.write_bytes(self.attest_test_bytes(raw))
                    manifest.write_text(json.dumps(self.manifest), encoding="utf-8")
                    result = self.cli(report, manifest, 3)
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(result.stdout, "")
                    self.assertTrue(result.stderr.startswith("pr_annotations: "))
                    self.assertNotIn("::error", result.stderr)


if __name__ == "__main__":
    unittest.main()
