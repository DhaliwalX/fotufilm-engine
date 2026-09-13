#!/usr/bin/env python3
"""Exercise object reuse and invalidation with the real Apple compiler drivers."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("compile-if-needed.py").resolve()
spec = importlib.util.spec_from_file_location("compile_if_needed", HELPER)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CompileReuseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="compile reuse ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.source = self.inputs / "source.cpp"
        self.header = self.inputs / "header.h"
        self.output = self.root / "objects" / "source.o"
        self.header.write_text("#define VALUE 1\n")
        self.source.write_text('#include "header.h"\nint value() { return VALUE; }\n')
        self.command = ["xcrun", "clang++", "-isysroot", self.sdk, "-I" + str(self.inputs),
                        "-O2", "-c", str(self.source), "-o", str(self.output)]

    def compile(self, command=None, environment=None, success=True):
        result = subprocess.run(["python3", str(HELPER), *(command or self.command)],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout

    def prime(self):
        self.compile()
        self.assertIn("Reusing", self.compile())

    def test_unchanged_content_and_changed_timestamps_reuse(self):
        self.prime()
        os.utime(self.source, None)
        self.assertIn("Reusing", self.compile())

    def test_source_and_header_changes_invalidate_even_with_same_timestamp(self):
        self.prime()
        for path in (self.source, self.header):
            with self.subTest(path=path.name):
                stat = path.stat()
                path.write_text(path.read_text() + "\n// edit\n")
                os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                self.assertNotIn("Reusing", self.compile())
                self.assertIn("Reusing", self.compile())

    def test_flags_and_environment_invalidate(self):
        self.prime()
        self.assertNotIn("Reusing", self.compile(self.command + ["-DNEW_FLAG=1"]))
        env = dict(os.environ, CPLUS_INCLUDE_PATH=str(self.root))
        self.assertNotIn("Reusing", self.compile(environment=env))
        self.assertIn("Reusing", self.compile(environment=env))
        env["FOTUFILM_BUILD_CACHE"] = "0"
        self.assertNotIn("Reusing", self.compile(environment=env))

    def test_new_header_can_shadow_previous_dependency(self):
        nested = self.root / "nested"
        preferred = self.root / "preferred"
        nested.mkdir()
        preferred.mkdir()
        self.source.write_text('#include <chosen.h>\nint value() { return VALUE; }\n')
        (nested / "chosen.h").write_text("#define VALUE 1\n")
        self.command[2:2] = ["-I" + str(preferred), "-I" + str(nested)]
        self.prime()
        (preferred / "chosen.h").write_text("#define VALUE 2\n")
        self.assertNotIn("Reusing", self.compile())

    def test_deleted_or_corrupt_output_and_stamp_invalidate(self):
        self.prime()
        self.output.write_bytes(b"corrupt")
        self.assertNotIn("Reusing", self.compile())
        self.output.unlink()
        self.assertNotIn("Reusing", self.compile())
        self.output.with_suffix(".compile.json").write_text("invalid JSON")
        self.assertNotIn("Reusing", self.compile())

    def test_compiler_failure_cannot_reuse_previous_object(self):
        self.prime()
        self.header.write_text("#error intentional failure\n")
        self.compile(success=False)
        self.assertFalse(self.output.with_suffix(".compile.json").exists())
        self.header.write_text("#define VALUE 2\n")
        self.assertNotIn("Reusing", self.compile())

    def test_swift_whole_module_object_and_system_dependencies(self):
        source = self.inputs / "source.swift"
        source.write_text('import Foundation\npublic func value() -> String { "one" }\n')
        self.command = ["xcrun", "swiftc", "-sdk", self.sdk, "-O", "-whole-module-optimization",
                        "-g", "-module-name", "SeparateModuleName",
                        "-parse-as-library", "-emit-object", str(source), "-o", str(self.output)]
        self.compile()
        self.assertIn("Reusing", self.compile())
        record = json.loads(self.output.with_suffix(".compile.json").read_text())
        self.assertTrue(any(path.startswith(self.sdk) for path in record["inputs"]))
        source.write_text(source.read_text().replace('"one"', '"two"'))
        self.assertNotIn("Reusing", self.compile())

    def test_dependency_parser_handles_make_escaping(self):
        depfile = self.root / "escape.d"
        depfile.write_text("out.o: space\\ name.h \\\n dollar$$name.h hash\\#name.h slash\\\\name.h\n")
        self.assertEqual(cache.dependencies(depfile),
                         ["dollar$name.h", "hash#name.h", "slash\\name.h", "space name.h"])


if __name__ == "__main__":
    unittest.main()
