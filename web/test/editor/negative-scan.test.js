import test from "node:test";
import assert from "node:assert/strict";
import {
  FULL_AREA,
  adoptConversion,
  aspectRatio,
  carriesColour,
  centredCrop,
  contrastForGrade,
  createHistory,
  gradeForContrast,
  historyReducer,
  orient,
  paperOf,
  rotateLeft,
  toggleMirror,
  unorient,
  unorientArea,
} from "../../src/negative-scan/recipe.js";
import { cropDrag, hitCrop } from "../../src/negative-scan/crop-drag.js";
import { previewRequest } from "../../src/negative-scan/useNegativeScanSession.js";
import { createDesktopBackend } from "../../src/backend/desktop/host.js";
import { createNativeBackend } from "../../src/backend/native.js";

const recipe = (fields = {}) => ({
  conversion: "automatic",
  monochrome: false,
  stockID: "gold200",
  paperID: "screen",
  exposure: 0,
  warmth: 0,
  tint: 0,
  contrast: 0,
  highlights: 0,
  shadows: 0,
  quarterTurns: 0,
  mirrored: false,
  straighten: 0,
  crop: { ...FULL_AREA },
  attachments: {},
  ...fields,
});

const close = (a, b) =>
  ["x", "y", "width", "height"].forEach((key) =>
    assert.ok(Math.abs(a[key] - b[key]) < 1e-9, `${key}: ${a[key]} vs ${b[key]}`),
  );

test("orientation maps as NegativeScanRecipe does and inverts", () => {
  // A clockwise quarter turn puts the scan's left edge at the top.
  assert.deepEqual(orient(recipe({ quarterTurns: 1 }), [0, 0.25]), [0.75, 0]);
  for (const quarterTurns of [0, 1, 2, 3])
    for (const mirrored of [false, true]) {
      const r = recipe({ quarterTurns, mirrored });
      const [x, y] = unorient(r, orient(r, [0.2, 0.7]));
      assert.ok(Math.abs(x - 0.2) < 1e-12 && Math.abs(y - 0.7) < 1e-12);
    }
});

test("turning and flipping keep the crop on the same part of the scan", () => {
  const start = recipe({ crop: { x: 0.1, y: 0.2, width: 0.3, height: 0.5 }, straighten: 3 });
  const kept = unorientArea(start, start.crop);
  const turned = rotateLeft(start);
  assert.equal(turned.quarterTurns, 3);
  close(unorientArea(turned, turned.crop), kept);
  const flipped = toggleMirror(turned);
  // A flip on a turned picture takes a half turn with it, and the tilt leans the other way.
  assert.equal(flipped.quarterTurns, 1);
  assert.equal(flipped.mirrored, true);
  assert.equal(flipped.straighten, -3);
  close(unorientArea(flipped, flipped.crop), kept);
});

test("paper grade and contrast are one scale", () => {
  assert.equal(contrastForGrade(2), 0);
  assert.equal(gradeForContrast(1 / 3), 3);
  assert.equal(contrastForGrade(9), 1);
});

test("colour, receiver and the pasted conversion follow the recipe", () => {
  const films = [
    { id: "gold200", monochrome: false, papers: [{ id: "screen" }, { id: "crystalArchive" }] },
    { id: "hp5", monochrome: true, papers: [{ id: "screen" }] },
  ];
  assert.equal(carriesColour(recipe({ monochrome: true }), films), false);
  assert.equal(carriesColour(recipe({ conversion: "film", stockID: "hp5" }), films), false);
  assert.equal(paperOf(recipe({ conversion: "film", paperID: "crystalArchive" }), films).id, "crystalArchive");
  assert.equal(paperOf(recipe({ conversion: "film", stockID: "hp5", paperID: "crystalArchive" }), films).id, "screen");
  const pasted = adoptConversion(recipe({ quarterTurns: 2 }), recipe({ conversion: "film", exposure: 1, quarterTurns: 1 }));
  assert.equal(pasted.conversion, "film");
  assert.equal(pasted.exposure, 1);
  assert.equal(pasted.quarterTurns, 2);
});

test("a slider's run is one step of history", () => {
  let state = createHistory(recipe());
  for (const exposure of [0.1, 0.2, 0.3])
    state = historyReducer(state, { type: "edit", stroke: true, change: (r) => ({ ...r, exposure }) });
  state = historyReducer(state, { type: "endStroke" });
  state = historyReducer(state, { type: "edit", change: (r) => ({ ...r, mirrored: true }) });
  assert.equal(state.undo.length, 2);
  state = historyReducer(state, { type: "undo" });
  assert.equal(state.recipe.exposure, 0.3);
  assert.equal(state.recipe.mirrored, false);
  state = historyReducer(state, { type: "undo" });
  assert.equal(state.recipe.exposure, 0);
  state = historyReducer(state, { type: "redo" });
  assert.equal(state.recipe.exposure, 0.3);
  // An edit that changes nothing is no step.
  assert.equal(historyReducer(state, { type: "edit", change: (r) => ({ ...r }) }), state);
});

test("crop drags move, resize from the opposite corner and hold an aspect", () => {
  const crop = { x: 0.2, y: 0.2, width: 0.4, height: 0.4 };
  assert.equal(hitCrop(crop, [0.2, 0.2], 0.02), "nw");
  assert.equal(hitCrop(crop, [0.4, 0.4], 0.02), "move");
  assert.equal(hitCrop(crop, [0.9, 0.9], 0.02), "new");
  assert.equal(hitCrop({ x: 0, y: 0, width: 1, height: 1 }, [0.5, 0.5], 0.02), "new");
  close(cropDrag({ start: [0.4, 0.4], crop, hit: "move" }, [0.9, 0.5], null, 1),
    { x: 0.6, y: 0.3, width: 0.4, height: 0.4 });
  close(cropDrag({ start: [0.6, 0.6], crop, hit: "se" }, [0.8, 0.7], null, 1),
    { x: 0.2, y: 0.2, width: 0.6, height: 0.5 });
  // 3:2 on a 3:2 picture is a unit square.
  const locked = cropDrag({ start: [0.1, 0.1], crop, hit: "new" }, [0.5, 0.9], 1.5, 1.5);
  assert.ok(Math.abs(locked.width - locked.height) < 1e-9);
  assert.equal(aspectRatio("3:2", 0.8), 2 / 3);
  close(centredCrop(1, 2), { x: 0.25, y: 0, width: 0.5, height: 1 });
});

test("the canvas shows the whole negative while picking and the uncropped print while framing", () => {
  assert.deepEqual(previewRequest({ tab: "convert", picking: true }), { negative: true, cropped: false });
  assert.deepEqual(previewRequest({ tab: "frame" }), { negative: false, cropped: false });
  assert.deepEqual(previewRequest({ tab: "convert", showNegative: true }), { negative: true, cropped: true });
});

test("a host offers the negative-scan session only when its engine says so", async () => {
  const calls = [];
  const channel = (capabilities) => ({
    binary: true,
    capabilities,
    async postMessage(message, payload) {
      calls.push({ ...message, payload });
      if (message.method === "negativeScanRender")
        return { preview: new Uint8Array([1, 2]), previewType: "image/png", width: 4, height: 3, colorSpace: "display-p3" };
      if (message.method === "negativeScanDetectFrame") return { crop: null };
      return { handle: 7 };
    },
  });
  assert.equal(createDesktopBackend(channel({})).negativeScans, undefined);
  const host = createDesktopBackend(channel({ negativeScans: true, negativeScanEncoding: true }));
  assert.equal(host.negativeScans.encoding, true);
  const file = { name: "scan.tif", arrayBuffer: async () => new ArrayBuffer(3) };
  await host.negativeScans.open(file, { linearSamples: true });
  assert.equal(calls.at(-1).method, "negativeScanOpen");
  assert.deepEqual(calls.at(-1).params, { linearSamples: true, name: "scan.tif" });
  assert.equal(calls.at(-1).payload.byteLength, 3);
  const frame = await host.negativeScans.render(7, recipe(), { maxEdge: 1200, cropped: false });
  assert.equal(calls.at(-1).params.cropped, false);
  assert.equal(frame.width, 4);
  assert.equal(await host.negativeScans.detectFrame(7, recipe()), null);
  // The native backend carries the session through.
  const native = createNativeBackend({ ...host, lenses: host.lenses });
  assert.equal(native.negativeScans, host.negativeScans);
});
