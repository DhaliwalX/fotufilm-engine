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
  parsePrintFrameEdgePrinting,
  parsePrintFrameMargin,
  parsePrintFrameNumber,
  stripSource,
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
test("border width survives save/load/undo, reaches the frame plan and rejects out-of-range values", () => {
  const edit = { ...defaultEdit(), printFrame: "mount", printFrameMargin: 2.5 };
  const loaded = parseEdit(JSON.stringify({ version: 1, edit }), []);
  assert.equal(loaded.printFrameMargin, 2.5);
  assert.equal(frameRequest(loaded).margin, 2.5);
  delete edit.printFrameMargin;
  assert.equal(parseEdit(JSON.stringify({ version: 1, edit }), []).printFrameMargin, 1);
  assert.equal(frameRequest(defaultEdit()).margin, 1);
  for (const value of [-0.1, 3.1, NaN, "2"])
    assert.throws(() => parsePrintFrameMargin(value), /Invalid print frame border width/);
  const widened = historyReducer(initialHistory, {
    type: "edit",
    patch: { printFrameMargin: 0 },
  });
  assert.equal(widened.present.printFrameMargin, 0);
  assert.equal(historyReducer(widened, { type: "undo" }).present.printFrameMargin, 1);
});
test("film border frame number and edge printing survive save/load and reach the frame plan", () => {
  const edit = { ...defaultEdit(), printFrame: "film", printFrameNumber: 23, printFrameEdgePrinting: false };
  const loaded = parseEdit(JSON.stringify({ version: 1, edit }), []);
  assert.equal(loaded.printFrameNumber, 23);
  assert.equal(loaded.printFrameEdgePrinting, false);
  assert.equal(frameRequest(loaded).frameNumber, 23);
  assert.equal(frameRequest(loaded).edgePrinting, false);
  delete edit.printFrameNumber;
  delete edit.printFrameEdgePrinting;
  const older = parseEdit(JSON.stringify({ version: 1, edit }), []);
  assert.equal(older.printFrameNumber, 1);
  assert.equal(older.printFrameEdgePrinting, true);
  assert.equal(frameRequest(defaultEdit()).frameNumber, 1);
  assert.equal(frameRequest(defaultEdit()).edgePrinting, true);
  for (const value of [-1, 39, 1.5, "2"])
    assert.throws(() => parsePrintFrameNumber(value), /Invalid film border frame number/);
  assert.throws(() => parsePrintFrameEdgePrinting(1), /Invalid film border edge printing/);
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

test('a film border strip continues the photograph past its edges', async () => {
  const data = new Float32Array(2 * 2 * 4)
  for (let i = 0; i < 4; i++) data.set([i, i, i, 1], i * 4)
  const source = {
    width: 2,
    height: 2,
    read(x, y, w, h) {
      const out = new Float32Array(w * h * 4)
      for (let row = 0; row < h; row++)
        out.set(data.subarray(((y + row) * 2 + x) * 4, ((y + row) * 2 + x + w) * 4), row * w * 4)
      return out
    },
  }
  const strip = stripSource(source, { left: 1, right: 2, top: 1, bottom: 0 })
  assert.equal(strip.width, 5)
  assert.equal(strip.height, 3)
  const whole = strip.read(0, 0, 5, 3)
  const at = (x, y) => whole[(y * 5 + x) * 4]
  // The photograph's own pixels sit inside its margins; beyond, the nearest edge pixel.
  assert.deepEqual([at(1, 1), at(2, 1), at(1, 2), at(2, 2)], [0, 1, 2, 3])
  assert.deepEqual([at(0, 0), at(4, 0), at(0, 2), at(4, 2)], [0, 1, 2, 3])
  const part = strip.read(3, 1, 2, 2)
  assert.deepEqual([part[0], part[4], part[8], part[12]], [1, 1, 3, 3])
  const promised = await stripSource({ ...source, read: (...a) => Promise.resolve(source.read(...a)) },
    { left: 1, right: 0, top: 0, bottom: 0 }).read(0, 0, 3, 1)
  assert.deepEqual([promised[0], promised[4], promised[8]], [0, 0, 1])
})
