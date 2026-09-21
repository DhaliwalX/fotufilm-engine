import test from "node:test";
import assert from "node:assert/strict";
import {
  rectangleCrop,
  isRectangleCrop,
  moveCrop,
  resizeCrop,
} from "../../src/crop-interaction.js";
import { validCrop, defaultEdit, parseEdit } from "../../src/editor-state.js";
import { outputSize } from "../../src/geometry.js";

test("rectangle handles retain their opposite anchor and locked aspect within the photograph", () => {
  const crop = rectangleCrop(0.2, 0.1, 0.8, 0.9);
  for (const grip of [0, 1, 2, 3, "left", "right", "top", "bottom"]) {
    for (const point of [
      [0, 0],
      [1, 1],
      [0.45, 0.6],
    ]) {
      const resized = resizeCrop(crop, grip, point, "rectangle", true);
      assert.ok(validCrop(resized));
      assert.ok(isRectangleCrop(resized));
      assert.ok(
        Math.abs(
          (resized[2][0] - resized[0][0]) / (resized[2][1] - resized[0][1]) -
            0.75,
        ) < 1e-9,
      );
    }
  }
  const moved = moveCrop(crop, 2, -2);
  assert.ok(validCrop(moved));
  assert.ok(isRectangleCrop(moved));
  assert.equal(moved[1][0], 1);
  assert.equal(moved[0][1], 0);
});
test("four-corner selection cannot cross and crop dimensions remain whole pixels", () => {
  const crop = rectangleCrop(0.1, 0.1, 0.9, 0.9);
  assert.deepEqual(resizeCrop(crop, 0, [0.95, 0.95], "corners", false), crop);
  const changed = resizeCrop(crop, 0, [0.2, 0.3], "corners", false);
  assert.ok(validCrop(changed));
  assert.ok(!isRectangleCrop(changed));
  const size = outputSize(changed, 137, 89);
  assert.ok(Number.isInteger(size.width) && Number.isInteger(size.height));
  const edit = { ...defaultEdit(), crop: changed, cropShape: "rectangle" };
  assert.throws(() => parseEdit(JSON.stringify({ version: 1, edit }), []));
});
