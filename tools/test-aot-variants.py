#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


HELPER = Path(__file__).with_name("generate-aot-variants.py").resolve()
spec = importlib.util.spec_from_file_location("generate_aot_variants", HELPER)
aot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aot)

SCHEMA = json.loads(aot.SCHEMA.read_text())


class VariantTableTests(unittest.TestCase):
    def setUp(self):
        self.table = aot.Table(SCHEMA)

    def test_every_variant_has_a_unique_name_and_a_nonzero_mask(self):
        names = [name for name, _, _ in self.table.variants]
        self.assertEqual(len(names), len(set(names)))
        for name, mask, _ in self.table.variants:
            self.assertNotEqual(mask, 0, name)

    def test_families_add_exactly_their_bit(self):
        for family in SCHEMA["families"]:
            plain = self.table.evaluate("ALL_STAGES")
            wrapped = self.table.evaluate(f"{family['name']}(ALL_STAGES)")
            self.assertEqual(wrapped, plain | self.table.bits[family["adds"]], family["name"])

    def test_a_family_call_and_its_bit_are_told_apart(self):
        self.assertEqual(self.table.evaluate("CRYSTAL(MTF)"),
                         self.table.bits["MTF"] | self.table.bits["CRYSTAL_GRAIN"])
        self.assertEqual(self.table.evaluate("CRYSTAL_GRAIN | MTF"),
                         self.table.bits["MTF"] | self.table.bits["CRYSTAL_GRAIN"])
        self.assertEqual(self.table.c_expression("CRYSTAL(MTF | FLARE)"),
                         "FOTUFILM_AOT_CRYSTAL(FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_FLARE)")

    def test_one_variant_per_exact_class_carries_every_stage(self):
        full = self.table.evaluate("FULL_STAGES")
        classes = {}
        for name, mask, _ in self.table.variants:
            classes.setdefault(mask & self.table.exact_bits, []).append((name, mask))
        for exact, members in classes.items():
            if exact & self.table.bits["NO_FILM"]:
                continue
            stages = [mask & self.table.stage_bits for _, mask in members]
            self.assertIn(full, [s & ~self.table.bits["CRYSTAL_GRAIN"] for s in stages],
                          f"class {exact:#x} has no full-stage variant: {members}")

    def test_the_delivery_encode_is_no_axis(self):
        for bit in ("ENCODE_OUT", "OUTPUT_LINEAR", "OUTPUT_POWER", "OUTPUT_LOG"):
            self.assertEqual(self.table.bits[bit] & (self.table.stage_bits | self.table.exact_bits), 0)

    def test_windowed_twins_fit_the_reach_the_shim_bounds(self):
        basic = self.table.evaluate("BASIC_STAGES")
        for name, mask, _ in self.table.windowed:
            self.assertEqual(mask & self.table.stage_bits & ~basic, 0, name)

    def test_axes_partition_the_selector_bits(self):
        self.assertEqual(self.table.stage_bits & self.table.exact_bits, 0)
        for name, mask, _ in self.table.variants:
            outside = mask & ~(self.table.stage_bits | self.table.exact_bits)
            self.assertEqual(outside, 0, f"{name} carries a bit no axis selects on: {outside:#x}")

    def test_each_variant_is_the_narrowest_for_its_own_request(self):
        for name, mask, _ in self.table.variants:
            best = None
            for other, candidate, _ in self.table.variants:
                if candidate & self.table.exact_bits != mask & self.table.exact_bits:
                    continue
                if candidate & mask != mask:
                    continue
                extra = bin(candidate & ~mask).count("1")
                if best is None or extra < best[0]:
                    best = (extra, other)
            self.assertEqual(best[0], 0, f"{name} is never the narrowest match; {best[1]} is")

    def test_every_grain_laying_donor_variant_has_a_crystal_twin(self):
        self.assertEqual(self.table.missing_donor_crystal_twins(), [])
        schema = copy.deepcopy(SCHEMA)
        schema["variants"] = [v for v in schema["variants"] if v["name"] != "color_float_crystal"]
        with self.assertRaisesRegex(ValueError, "color_float"):
            aot.Table(schema)

    def test_checked_in_outputs_are_current(self):
        self.assertEqual(aot.HEADER.read_text(), aot.render_header(self.table))
        self.assertEqual(aot.SHIM_INCLUDES.read_text(), aot.render_shim_includes(self.table))

    def test_shim_includes_name_every_archive_and_only_generated_ones(self):
        includes = aot.render_shim_includes(self.table)
        for archive in self.table.archives(windowed=True):
            self.assertIn(f'#include "{archive}.h"', includes)
        self.assertIn("#if FOTUFILM_AOT_WINDOWED_HOST", includes)

    def test_consumer_check_finds_a_missing_or_singly_listed_archive(self):
        archives = self.table.archives(windowed=False)
        complete = "\n".join(f"$(SRCROOT)/build/halide-ios/{a}.a" for a in archives) + "\n"
        complete += "\n".join(f"- $(SRCROOT)/build/halide-ios/{a}.a" for a in archives)
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp) / "project.yml"
            project.write_text(complete)
            self.assertEqual(aot.check_consumer(self.table, project), [])
            project.write_text(complete.replace(f"- $(SRCROOT)/build/halide-ios/{archives[3]}.a", ""))
            self.assertEqual(aot.check_consumer(self.table, project), [archives[3]])

    def test_unknown_names_are_rejected(self):
        schema = copy.deepcopy(SCHEMA)
        schema["variants"].append({"name": "bogus", "mask": "ALL_STAGES | NOT_A_BIT"})
        with self.assertRaises(ValueError):
            aot.Table(schema)
        schema = copy.deepcopy(SCHEMA)
        schema["variants"].append({"name": "color", "mask": "ALL_STAGES"})
        with self.assertRaises(ValueError):
            aot.Table(schema)


if __name__ == "__main__":
    unittest.main()
