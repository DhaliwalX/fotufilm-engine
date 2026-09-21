import test from "node:test";
import assert from "node:assert/strict";
import {
  defaultEdit,
  parseEdit,
  historyReducer,
  initialHistory,
} from "../../src/editor-state.js";
import {
  frameRenderEdit,
  frameSamplePoint,
  frameRequest,
  parsePrintFrame,
} from "../../src/print-frame.js";
import { frameNoise } from "../../src/frame-texture.js";

test("frames survive save/load/undo, old edits default to none, unknown frames are rejected", () => {
  const edit = { ...defaultEdit(), printFrame: "socialStory" };
  assert.equal(
    parseEdit(JSON.stringify({ version: 1, edit }), []).printFrame,
    "socialStory",
  );
  delete edit.printFrame;
  assert.equal(
    parseEdit(JSON.stringify({ version: 1, edit }), []).printFrame,
    "none",
  );
  assert.throws(() => parsePrintFrame("made-up"), /Invalid print frame/);
  const selected = historyReducer(initialHistory, {
    type: "edit",
    patch: { printFrame: "mount" },
  });
  assert.equal(
    historyReducer(selected, { type: "undo" }).present.printFrame,
    "none",
  );
});
test("transmission frame follows native medium override and retains the saved edit", () => {
  const edit = {
    ...defaultEdit("gold200"),
    medium: "endura-premier",
    profile: { printLight: "tungsten", negativeViewing: "scanner", push: 1 },
  };
  const output = frameRenderEdit(edit, {
    configuration: { frame: "film" },
    renderMedium: "negative",
  });
  assert.equal(output.medium, "negative");
  assert.equal(output.profile.negativeViewing, "light-box");
  assert.equal(output.profile.printLight, "reference");
  assert.equal(output.profile.push, 1);
  assert.equal(edit.medium, "endura-premier");
  assert.equal(edit.profile.negativeViewing, "scanner");
  assert.equal(
    frameRenderEdit(edit, { configuration: { frame: "none" } }),
    edit,
  );
  assert.equal(frameRequest(edit).viewingKelvin, 2856);
});
test("sampling converts the bordered canvas to photo coordinates and ignores margins", () => {
  const plan = {
    placement: {
      size: { width: 400, height: 500 },
      image: { x: 50, y: 200, width: 300, height: 200 },
    },
  };
  assert.deepEqual(frameSamplePoint([0.5, 0.4], plan), [0.5, 0.5]);
  assert.equal(frameSamplePoint([0.5, 0.05], plan), null);
  assert.equal(frameSamplePoint([0.01, 0.4], plan), null);
  assert.deepEqual(frameSamplePoint([0.5, 0.4], null), [0.5, 0.4]);
});
test("material noise is stable and bounded across negative and positive coordinates", () => {
  for (let x = -50; x < 50; x += 0.7) {
    const a = frameNoise(x, x * 0.3, 409);
    assert.ok(a >= -1 && a <= 1);
    assert.equal(a, frameNoise(x, x * 0.3, 409));
  }
  assert.notEqual(frameNoise(3, 4, 409), frameNoise(3, 4, 613));
});
