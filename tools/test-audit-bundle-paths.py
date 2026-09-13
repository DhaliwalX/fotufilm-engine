#!/usr/bin/env python3
"""Exercise the release path audit on binary and text bundle contents."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/audit-bundle-paths.py"


class BundlePathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bundle audit ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "Example.app"
        self.bundle.mkdir()

    def scan(self):
        return subprocess.run(["python3", str(HELPER), str(self.bundle)],
                              capture_output=True, text=True)

    def test_clean_empty_binary_and_relative_paths(self):
        (self.bundle / "empty").touch()
        (self.bundle / "asset").write_bytes(b"\x00\xff\xfeFotufilm/Sources/file.swift\x00/home/\x00")
        self.assertEqual(self.scan().returncode, 0)

    def test_ascii_and_unicode_paths_in_nested_binary_files(self):
        nested = self.bundle / "nested space"
        nested.mkdir()
        for path in (b"/Users/license-test/src/file", b"/home/build/project", b"/.claude/worktrees/task",
                     "/Users/José/source".encode()):
            with self.subTest(path=path):
                (nested / "binary").write_bytes(b"\x00\xff" + path + b"\x00")
                result = self.scan()
                self.assertEqual(result.returncode, 1)
                self.assertIn("local build path", result.stderr)

    def test_page_boundaries_and_long_names(self):
        for offset in (4093, 65533, 1048573):
            (self.bundle / "binary").write_bytes(b"\x00" * offset + b"/Users/" + b"a" * 8192 + b"/src\x00")
            self.assertEqual(self.scan().returncode, 1)

    def test_reports_every_file_and_does_not_follow_symlinks(self):
        outside = self.root / "outside"
        outside.write_bytes(b"/Users/license-test/secret")
        (self.bundle / "link").symlink_to(outside)
        self.assertEqual(self.scan().returncode, 0)
        for name in ("first", "second"):
            (self.bundle / name).write_bytes(b"/home/build/source")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("first", result.stderr)
        self.assertIn("second", result.stderr)

    def test_missing_bundle_fails(self):
        self.bundle.rmdir()
        self.assertNotEqual(self.scan().returncode, 0)

    def test_bundle_audit_propagates_path_failure(self):
        (self.bundle / "binary").write_bytes(b"\x00/Users/license-test/src\x00")
        result = subprocess.run(["bash", str(ROOT / "tools/audit-apple-bundle.sh"), str(self.bundle)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local build path", result.stderr)


if __name__ == "__main__":
    unittest.main()
