#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import unittest


HELPER = Path(__file__).with_name("generate-config-layout.py").resolve()
spec = importlib.util.spec_from_file_location("generate_config_layout", HELPER)
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)

SCHEMA = json.loads(layout.SCHEMA.read_text())


class LayoutTests(unittest.TestCase):
    def test_fields_are_contiguous_and_the_count_closes_the_last_one(self):
        constants, fields, total = layout.resolve(SCHEMA)
        offset = 0
        for field in fields:
            self.assertEqual(field["offset"], offset, field["name"])
            offset += field["count"]
        self.assertEqual(total, offset)
        self.assertEqual(constants["SAMPLED_CURVE_STRIDE"], 1 + 3 * 1024)

    def test_symbolic_counts_resolve_through_the_constants(self):
        _, fields, _ = layout.resolve(SCHEMA)
        by_name = {field["name"]: field for field in fields}
        self.assertEqual(by_name["COUPLER_WARP"]["count"], 3 * 128)
        self.assertEqual(by_name["TONE_GRID_A"]["count"], 64 * 64)
        self.assertEqual(by_name["SAMPLED_CURVES"]["count"], 3 * (1 + 3 * 1024))

    def test_generated_header_names_every_field_with_its_offset(self):
        constants, fields, total = layout.resolve(SCHEMA)
        header = layout.render(SCHEMA, constants, fields, total)
        for field in fields:
            self.assertIn(f"FOTUFILM_CONFIG_{field['name']} = {field['offset']},", header)
            self.assertIn(f"FOTUFILM_CONFIG_{field['name']}_COUNT = {field['count']},", header)
        self.assertIn(f"FOTUFILM_FRAME_CONFIGURATION_COUNT = {total}", header)
        self.assertIn("FOTUFILM_TONE_GRID_CELLS = FOTUFILM_TONE_GRID_EDGE * FOTUFILM_TONE_GRID_EDGE",
                      header)

    def test_checked_in_header_and_lock_are_current(self):
        constants, fields, total = layout.resolve(SCHEMA)
        self.assertEqual(layout.HEADER.read_text(),
                         layout.render(SCHEMA, constants, fields, total))
        self.assertEqual(json.loads(layout.LOCK.read_text()), layout.lock_record(fields, total))

    def test_appending_a_field_passes_the_lock(self):
        _, fields, total = layout.resolve(SCHEMA)
        previous = layout.lock_record(fields, total)
        schema = copy.deepcopy(SCHEMA)
        schema["fields"].append({"name": "NEW_STAGE", "count": 4})
        _, appended, appended_total = layout.resolve(schema)
        self.assertEqual(layout.check_lock(layout.lock_record(appended, appended_total),
                                           previous), [])

    def test_inserting_resizing_or_removing_a_field_fails_the_lock(self):
        _, fields, total = layout.resolve(SCHEMA)
        previous = layout.lock_record(fields, total)
        inserted = copy.deepcopy(SCHEMA)
        inserted["fields"].insert(3, {"name": "NEW_STAGE", "count": 4})
        problems = layout.check_lock(layout.lock_record(*layout.resolve(inserted)[1:]), previous)
        self.assertTrue(any("moved" in problem for problem in problems), problems)

        resized = copy.deepcopy(SCHEMA)
        resized["fields"][-1]["count"] = 99
        problems = layout.check_lock(layout.lock_record(*layout.resolve(resized)[1:]), previous)
        self.assertTrue(any("moved" in problem or "shrank" in problem for problem in problems),
                        problems)

        removed = copy.deepcopy(SCHEMA)
        del removed["fields"][-1]
        problems = layout.check_lock(layout.lock_record(*layout.resolve(removed)[1:]), previous)
        self.assertTrue(any("removed" in problem for problem in problems), problems)

    def test_an_empty_field_is_rejected(self):
        schema = copy.deepcopy(SCHEMA)
        schema["fields"].append({"name": "EMPTY", "count": 0})
        with self.assertRaises(ValueError):
            layout.resolve(schema)


if __name__ == "__main__":
    unittest.main()
