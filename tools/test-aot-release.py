#!/usr/bin/env python3
"""Offline regression tests for the public AOT archive and compiler-free fetch contract."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("aot_release", Path(__file__).with_name("aot-release.py"))
aot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aot)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.record = aot.identity("device")
        self.contents = {name: b"licence or header\n" for name in aot.HEADERS | aot.NOTICES}
        self.contents["fotufilm_halide_ios_color.a"] = b"!<arch>\nfixture"
        self.contents["fotufilm_halide_ios_color.h"] = b"// interface\n"
        self.manifest()

    def manifest(self):
        self.contents.pop(aot.MANIFEST, None)
        record = {**self.record, "source_commit": "1" * 40, "archive_count": 1,
                  "files": {name: aot.digest(data) for name, data in self.contents.items()}}
        self.contents[aot.MANIFEST] = json.dumps(record).encode()

    def archive(self, extra=None):
        archive = self.directory / "kernels.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for name, data in self.contents.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                bundle.addfile(entry, io.BytesIO(data))
            if extra is not None:
                bundle.addfile(extra, io.BytesIO(b"x" * extra.size))
        checksum = self.directory / "kernels.tar.gz.sha256"
        checksum.write_text(aot.digest(archive.read_bytes()) + "  kernels.tar.gz\n")
        return archive, checksum

    def unpack(self, record=None, extra=None):
        aot.unpack(*self.archive(extra), record or self.record, self.directory / "output")

    def test_verified_round_trip_and_compiler_free_cache(self):
        self.unpack()
        output = self.directory / "output"
        self.assertTrue(aot.cache_matches(self.record, output))
        environment = dict(os.environ, HALIDE_ROOT="/does-not-exist", FOTUFILM_AOT_REQUIRE_PREBUILT="1")
        for flag in aot.flags():
            environment.pop(flag, None)
        result = subprocess.run([str(aot.ROOT / "tools/generate-halide-aot.sh"), "device", str(output)],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified cached public AOT", result.stdout)

    def test_checksum_failure_preserves_previous_cache(self):
        self.unpack()
        archive, checksum = self.archive()
        archive.write_bytes(archive.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            aot.unpack(archive, checksum, self.record, self.directory / "output")
        self.assertTrue(aot.cache_matches(self.record, self.directory / "output"))

    def test_wrong_platform(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.unpack(aot.identity("simulator"))

    def test_traversal_links_duplicate_and_unlisted_files(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("/escape", tarfile.REGTYPE),
                           ("HalideBuffer.h", tarfile.SYMTYPE), ("HalideBuffer.h", tarfile.REGTYPE),
                           ("generate-halide-aot", tarfile.REGTYPE), (".generated-from", tarfile.REGTYPE)]:
            with self.subTest(name=name, kind=kind):
                entry = tarfile.TarInfo(name)
                entry.type, entry.size, entry.linkname = kind, 1, "../escape"
                with self.assertRaisesRegex(ValueError, "Unsafe or unexpected"):
                    self.unpack(extra=entry)

    def test_file_tampering_even_with_valid_outer_checksum(self):
        self.contents["fotufilm_halide_ios_color.a"] += b"bad"
        with self.assertRaisesRegex(ValueError, "checksum/allowlist"):
            self.unpack()

    def test_missing_file(self):
        self.contents.pop("HalideBuffer.h")
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.unpack()

    def test_cache_missing_and_changed_files(self):
        self.unpack()
        header = self.directory / "output/HalideBuffer.h"
        header.write_bytes(b"bad")
        self.assertFalse(aot.cache_matches(self.record, header.parent))
        header.unlink()
        self.assertFalse(aot.cache_matches(self.record, header.parent))

    def test_output_safety_and_unrelated_files_preserved(self):
        for path in (aot.ROOT, aot.ROOT.parent, Path.home(), Path("/")):
            with self.assertRaises(ValueError):
                aot.output_path(str(path))
        destination = self.directory / "output"
        destination.mkdir()
        (destination / "user.txt").write_text("keep")
        with self.assertRaisesRegex(ValueError, "unrelated"):
            self.unpack()
        self.assertEqual((destination / "user.txt").read_text(), "keep")
        link = self.directory / "link"
        link.symlink_to(destination)
        with self.assertRaises(ValueError):
            aot.output_path(str(link))

    def test_all_generator_overrides_disable_release_substitution(self):
        names = ("FOTUFILM_F16_BLUR", "FOTUFILM_METAL_MTF", "FOTUFILM_GPU_STRIDE",
                 "FOTUFILM_GPU_TILE", "FOTUFILM_GPU_TILE_X", "FOTUFILM_GPU_TILE_Y",
                 "FOTUFILM_STILL_FAST", "FOTUFILM_METAL_PRECOMPILE", "FOTUFILM_METAL_MATH_MODE")
        with patch.dict(os.environ, {name: "0" for name in names}, clear=True):
            self.assertEqual(set(aot.flags()), set(names))

    def test_download_is_anonymous_and_missing_is_distinct_from_corruption(self):
        with patch.object(aot.subprocess, "run") as request:
            request.return_value = subprocess.CompletedProcess([], 22, "", "HTTP 404")
            self.assertEqual(aot.fetch(self.record, self.directory / "output"), 3)
            arguments = request.call_args.args[0]
            self.assertEqual(arguments[:2], ["curl", "-q"])
            self.assertNotIn("Authorization", " ".join(arguments))
            self.assertIn("https://github.com/DhaliwalX/fotufilm-engine/releases/download/", arguments[-1])

    def test_parity_harness_keeps_consumer_output_location(self):
        fixture = self.directory / "consumer"
        (fixture / "tools").mkdir(parents=True)
        shutil.copyfile(aot.ROOT / "tools/verify-aot-parity.sh", fixture / "tools/verify-aot-parity.sh")
        stubs = {
            "tools/resolve-halide-toolchain.sh": "printf '/compiler\\n'",
            "tools/generate-halide-aot.sh": 'printf "%s\\n" "$@" "$FOTUFILM_AOT_NO_FETCH"; exit 42',
            "bin/xcrun": "printf '/sdk\\n'",
            "bin/sysctl": "printf '1\\n'",
        }
        for name, body in stubs.items():
            path = fixture / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        result = subprocess.run(["bash", str(fixture / "tools/verify-aot-parity.sh")],
                                env={"PATH": str(fixture / "bin") + ":" + os.defpath},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["macos", str(fixture / "build/halide-macos"), "1"])

    def test_key_uses_public_sources_and_toolchain_not_consumer_or_installed_paths(self):
        fixture = self.directory / "engine"
        for name in self.record["inputs"]:
            target = fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(aot.ROOT / name, target)
        with patch.object(aot, "ROOT", fixture), patch.object(aot, "halide_revision", return_value=self.record["halide_revision"]):
            initial = aot.identity("device")["key"]
            self.assertEqual(initial, self.record["key"])
            app = fixture / "ios/MatrixBenchmark.cpp"
            app.parent.mkdir()
            app.write_text("consumer-only code")
            with patch.dict(os.environ, {"HALIDE_ROOT": "/not-installed"}):
                self.assertEqual(aot.identity("device")["key"], initial)
            # CPU-only code and the AOT host shim do not enter the Metal generator.
            # Editing either must not regenerate hundreds of identical archives.
            for name in ("FotufilmHalide.cpp", "FotufilmHalideIOS.cpp", "FotufilmMetalGrain.mm"):
                (fixture / "Sources/FotufilmHalide" / name).write_text("unrelated implementation\n")
                self.assertEqual(aot.identity("device")["key"], initial)
            shared = fixture / "Sources/FotufilmHalide/FotufilmHalideShared.h"
            shared.write_text(shared.read_text() + '\n#include "AdditionalKernel.h"\n')
            added = shared.with_name("AdditionalKernel.h")
            with self.assertRaisesRegex(ValueError, "Missing AOT generator include"):
                aot.identity("device")
            added.write_text("// new transitive dependency\n")
            self.assertIn(str(added.relative_to(fixture)), aot.generator_inputs())
            changed = aot.identity("device")["key"]
            self.assertNotEqual(changed, initial)
            added.write_text("// changed transitive dependency\n")
            self.assertNotEqual(aot.identity("device")["key"], changed)
            shared.write_text(shared.read_text() + "\n#include DYNAMIC_HEADER\n")
            with self.assertRaisesRegex(ValueError, "literal include"):
                aot.identity("device")
            shared.write_text(shared.read_text().replace("\n#include DYNAMIC_HEADER\n", ""))
            initial = aot.identity("device")["key"]
            toolchain = fixture / "tools/aot-toolchain.json"
            toolchain.write_text(toolchain.read_text() + "\n")
            self.assertNotEqual(aot.identity("device")["key"], initial)


if __name__ == "__main__":
    unittest.main()
