import test from "node:test";
import assert from "node:assert/strict";
import {
  exportBasis,
  exportMaxEdge,
  exportPixels,
  exportSizeOptions,
  resolutionLimitWarning,
} from "../../src/export-sizes.js";

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

test("a backend measuring the crop sizes the cropped picture, rounding outward", () => {
  const crop = { width: 1800, height: 2248 };
  const options = exportSizeOptions(3000, 4496, false, crop, true);
  assert.deepEqual(options.map(({ id }) => id), ["full", "0.75", "0.5", "2048", "1600"]);
  assert.equal(options[0].detail, "1800 × 2248");
  assert.equal(options.find(({ id }) => id === "1600").detail, "1282 × 1600");
  assert.equal(exportMaxEdge("0.5", ...exportBasis(3000, 4496, crop, true)), 1124);
  // 2848 x 512/4288 is 340.06: Core Image delivers 341 rows, as the host does.
  assert.deepEqual(exportPixels(512, 4288, 2848, { width: 4288, height: 2848 }, true),
    { width: 512, height: 341 });
  // Within half a pixel of the picture is the picture.
  assert.deepEqual(exportPixels(2248, 3000, 4496, { width: 1800, height: 2248.3 }, true),
    { width: 1800, height: 2248.3 });
});

test("sizes past the backend's memory limit read as the Mac app's export sheet does", () => {
  const sizes = exportSizeOptions(6000, 4000);
  assert.deepEqual(sizes[1].pixels, { width: 4500, height: 3000 });
  assert.equal(resolutionLimitWarning(sizes, "full", []), null);
  assert.equal(
    resolutionLimitWarning(sizes, "0.75", ["full"]),
    "Resolution reduced: Full resolution exceeds this device’s safe memory limit. Large (4500 × 3000) is selected instead, so the export will contain fewer pixels.",
  );
  assert.match(
    resolutionLimitWarning(sizes, "full", sizes.map(({ id }) => id)),
    /^Resolution unavailable/,
  );
});
