import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit, parseEdit } from "../../src/editor-state.js";
import { hasProfileSettings } from "../../src/profile-settings.js";
import {
  parseLensFilters,
  filterNote,
  isDiffusion,
} from "../../src/lens-filters.js";
import { LENS_FILTERS } from "../../src/generated/controls.js";

test("ordered filter stacks and metering round-trip with duplicate filters intact", () => {
  const edit = {
    ...defaultEdit("gold200"),
    filters: ["w85b", "blackpromist-1/2", "w85b", "fog-1"],
    filterMetering: "filmSpeed",
  };
  const restored = parseEdit(JSON.stringify({ version: 1, edit }), ["gold200"]);
  assert.deepEqual(restored, edit);
  assert.equal(hasProfileSettings(restored), true);
  assert.match(filterNote(restored), /Only the first diffusion filter acts/);
  assert.match(filterNote(restored), /green-sensitive/);
  assert.equal(isDiffusion("w85b"), false);
  assert.equal(isDiffusion("blackpromist-1/2"), true);
  assert.equal(isDiffusion("unknown-1"), false);
});

test("older edits default to bare glass and invalid filter files are rejected", () => {
  assert.deepEqual(parseLensFilters({}), {
    filters: [],
    filterMetering: "throughTheLens",
  });
  assert.equal(
    hasProfileSettings({
      ...defaultEdit(),
      filters: [],
      filterMetering: "filmSpeed",
    }),
    false,
  );
  for (const edit of [
    { filters: "w85b" },
    { filters: ["unknown"] },
    { filters: [null] },
    { filterMetering: "unknown" },
  ])
    assert.throws(() => parseLensFilters(edit));
  assert.deepEqual(parseLensFilters({ filters: ["nd09"] }).filters, ["nd09"]);
  assert.ok(LENS_FILTERS.names.nd09);
  assert.equal(LENS_FILTERS.choices.length, 38);
});
