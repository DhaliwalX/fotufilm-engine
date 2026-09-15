#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("prune", Path(__file__).with_name("prune-aot-releases.py"))
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)


def release(tag, draft=False):
    return {"tag_name": tag, "draft": draft,
            "assets": [{"name": name, "state": "uploaded", "size": 1} for name in prune.ASSETS]}


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.required = {f"aot-{p}-{'a' * 16}" for p in prune.PLATFORMS}
        self.current = [release(tag) for tag in self.required]

    def test_preserves_each_platform_and_unrelated_releases(self):
        old = "aot-device-" + "b" * 16
        rows = self.current + [release(old), release("v1.8.1"), release("site-demo-2026-09-15")]
        self.assertEqual(prune.obsolete_releases(rows, self.required), [old])

    def test_missing_replacement_prevents_deletion(self):
        with self.assertRaises(ValueError):
            prune.obsolete_releases(self.current[:-1], self.required)

    def test_draft_replacement_prevents_deletion(self):
        self.current[0]["draft"] = True
        with self.assertRaises(ValueError):
            prune.obsolete_releases(self.current, self.required)

    def test_incomplete_replacement_prevents_deletion(self):
        self.current[0]["assets"].pop()
        with self.assertRaises(ValueError):
            prune.obsolete_releases(self.current, self.required)

    def test_failed_upload_prevents_deletion(self):
        self.current[0]["assets"][0]["size"] = 0
        with self.assertRaises(ValueError):
            prune.obsolete_releases(self.current, self.required)

    def test_does_not_delete_drafts_or_unrecognized_tags(self):
        rows = self.current + [release("aot-device-" + "b" * 16, draft=True), release("aot-device-manual")]
        self.assertEqual(prune.obsolete_releases(rows, self.required), [])


if __name__ == "__main__":
    unittest.main()
