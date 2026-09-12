#!/usr/bin/env python3
"""Check that scheduling cannot silently lose tests or hide runner failures."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("test_engine", Path(__file__).with_name("test-engine.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class RunnerTests(unittest.TestCase):
    def test_discovery_rejects_empty_duplicate_or_unsupported_tests(self):
        for output in ["", "M.C/test\nM.C/test", "M.C/test(value:)", "error: failed to list tests"]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                engine.discover(output)
        self.assertEqual(engine.discover("M.C/testB\nM.C/testA\n"), ["M.C/testA", "M.C/testB"])

    def test_every_class_stays_together_and_every_test_runs_once(self):
        tests = [f"Module.Class{c}/test{t}" for c in range(13) for t in range(c + 1)]
        for count in [1, 2, 4, 99]:
            groups = engine.partition(tests, count, {})
            self.assertEqual(sorted(test for group in groups for test in group), sorted(tests))
            owners = {}
            for index, group in enumerate(groups):
                for test in group:
                    name = test.split("/")[0]
                    self.assertEqual(owners.setdefault(name, index), index)
        self.assertEqual(engine.partition([], 4, {}), [])

    def test_measured_costs_balance_whole_classes(self):
        groups = engine.partition(["M.A/a", "M.B/b", "M.C/c", "M.D/d"], 2,
                                  {"M.A/a": 9, "M.B/b": 8, "M.C/c": 2, "M.D/d": 1})
        self.assertEqual(groups, [["M.A/a", "M.D/d"], ["M.B/b", "M.C/c"]])

    def test_skips_count_but_missing_duplicates_and_failures_never_pass(self):
        tests = ["M.C/a", "M.C/b"]
        results = [{"test": "M.C/a", "status": "passed"},
                   {"test": "M.C/b", "status": "skipped"}]
        self.assertEqual(engine.audit(tests, results), [])
        self.assertTrue(engine.audit(tests, results[:1]))
        self.assertTrue(engine.audit(tests, results + results[:1]))
        results[1]["status"] = "failed"
        self.assertTrue(engine.audit(tests, results))

    def test_real_xctest_output_formats_include_skips_and_failures(self):
        tests = ["M.C/a", "M.C/b", "M.C/c"]
        for platform, names in [("darwin", ["-[M.C a]", "-[M.C b]", "-[M.C c]"]),
                                ("linux", ["C.a", "C.b", "C.c"])]:
            output = "\n".join(f"Test Case '{name}' {status} (0.012 seconds)."
                               for name, status in zip(names, ["passed", "skipped", "failed"]))
            with patch.object(engine.sys, "platform", platform):
                results = engine.results_from_log(output, tests)
            self.assertEqual([result["test"] for result in results], tests)
            self.assertEqual([result["status"] for result in results], ["passed", "skipped", "failed"])

    def test_history_is_optional_and_rejects_nonfinite_weights(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            self.assertEqual(engine.timing_history(path), {})
            path.write_text("truncated {")
            self.assertEqual(engine.timing_history(path), {})
            path.write_text('{"workers":[{"results":['
                            '{"test":"M.A/a","seconds":2.5},'
                            '{"test":"M.B/b","seconds":NaN},'
                            '{"test":"M.C/c","seconds":-1}]}]}')
            self.assertEqual(engine.timing_history(path), {"M.A/a":2.5})

    def test_timeout_is_fatal_and_stops_the_process_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / "runner"
            fake.write_text("#!/bin/sh\ntrap '' TERM\nsleep 20\n")
            fake.chmod(0o755)
            with patch.object(engine.sys, "platform", "darwin"):
                result = engine.run_group(1, ["M.C/a"], str(fake), root, root, 1)
            self.assertEqual(result["exit_code"], 124)
            self.assertTrue(result["problems"])
            self.assertFalse(engine.RUNNING)

    def test_process_failure_is_fatal_even_when_all_tests_printed_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake = root / "runner"
            fake.write_text("#!/bin/sh\nprintf \"Test Case '-[M.C a]' passed (0.001 seconds).\\n\"\nexit 7\n")
            fake.chmod(0o755)
            with patch.object(engine.sys, "platform", "darwin"):
                result = engine.run_group(1, ["M.C/a"], str(fake), root, root, 5)
            self.assertEqual(result["exit_code"], 7)
            self.assertEqual(len(result["results"]), 1)
            self.assertTrue(result["problems"])

    def test_zero_tests_from_successful_process_is_fatal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(engine.sys, "platform", "darwin"):
                result = engine.run_group(1, ["M.C/a"], "/usr/bin/true", root, root, 5)
            self.assertEqual(result["exit_code"], 0)
            self.assertTrue(result["problems"])


if __name__ == "__main__":
    unittest.main()
