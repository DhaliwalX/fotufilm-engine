import assert from "node:assert/strict";
import test from "node:test";
import { defaultEdit } from "../../src/editor-state.js";
import { thumbnailEdit } from "../../src/editor/useThumbnail.js";

test("thumbnails leave halation and grain off and keep the rest of the edit", () => {
  const edit = {
    ...defaultEdit("portra400"),
    halationModel: "layered",
    profile: { halation: 4, antiHalation: 0.5 },
    params: { ...defaultEdit().params, grain: 1.5, exposure: 0.3 },
  };
  const shown = thumbnailEdit(edit);
  assert.equal(shown.halationModel, "legacy");
  assert.equal(shown.profile.halation, 0);
  assert.equal(shown.params.grain, 0);
  assert.equal(shown.params.exposure, 0.3);
  assert.equal(shown.stock, "portra400");
  assert.equal(edit.params.grain, 1.5);
});
