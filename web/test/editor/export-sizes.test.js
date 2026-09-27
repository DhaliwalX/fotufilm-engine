import test from "node:test";
import assert from "node:assert/strict";
import { exportMaxEdge, exportSizeOptions } from "../../src/export-sizes.js";

test("a photo offers the Mac app's Large, Medium and Small, then the long edges", () => {
  const options = exportSizeOptions(6000, 4000);
  assert.deepEqual(
    options.map(({ id }) => id),
    ["full", "0.75", "0.5", "0.25", "3840", "2048", "1600"],
  );
  assert.equal(options[0].detail, "6000 × 4000");
  assert.equal(options[2].detail, "3000 × 2000");
  // A crop is what the sizes deliver.
  assert.equal(exportSizeOptions(6000, 4000, false, { width: 3000, height: 3000 })[1].detail, "2250 × 2250");
});

test("small pictures drop sizes that are no smaller or too small, and movies use video sizes", () => {
  assert.deepEqual(exportSizeOptions(1600, 1200).map(({ id }) => id), ["full", "0.75", "0.5"]);
  assert.deepEqual(
    exportSizeOptions(3840, 2160, true).map(({ label }) => label),
    ["Source", "1440p", "1080p", "720p"],
  );
});

test("an export size becomes the long edge it asks for", () => {
  assert.equal(exportMaxEdge("full", 6000, 4000), Infinity);
  assert.equal(exportMaxEdge("0.5", 6000, 4000), 3000);
  assert.equal(exportMaxEdge("2048", 6000, 4000), 2048);
});
