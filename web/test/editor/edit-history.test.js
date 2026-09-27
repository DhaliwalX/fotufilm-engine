import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit, historyReducer, initialHistory } from "../../src/editor-state.js";
import {
  editHistory,
  filmNamer,
  historyTitle,
  redoTitle,
  undoTitle,
} from "../../src/edit-history.js";

const films = filmNamer([
  { id: "gold200", name: "Gold 200" },
  { id: "portra400", name: "Portra 400" },
]);
const opened = defaultEdit("gold200");
const edit = (state, patch) => ({ ...state, ...patch });

test("each step is named after what it changed, as the Mac app names it", () => {
  const cases = [
    [{ stock: "portra400" }, "Portra 400"],
    [{ stock: null }, "Normal"],
    [{ lens: { ...opened.lens, amount: 0.5 } }, "Lens Correction"],
    [{ rotation: 1 }, "Crop & Rotate"],
    [{ filters: ["uv"] }, "Lens Filters"],
    [{ params: { ...opened.params, ev: 1 } }, "Light"],
    [{ params: { ...opened.params, temperature: 5000 } }, "Undertone"],
    [{ params: { ...opened.params, saturation: 1.2 } }, "Color"],
    [{ params: { ...opened.params, gradeShadowsWarmth: 0.3 } }, "Grade"],
    [{ profile: { halation: 0.4 } }, "Halation"],
    [{ profile: { couplers: 0.4 } }, "Couplers"],
    [{ profile: { push: 1 } }, "Lab"],
    [{ profile: { grainModel: "film" } }, "Grain"],
    [{ profile: { printerLamp: 3000 } }, "Enlarger"],
    [{ medium: "ra4" }, "Output Medium"],
    [{ digitalReference: "graded-print" }, "Screen Conversion"],
    [{ seed: 7 }, "Grain Pattern"],
    [{}, "Edit"],
  ];
  for (const [patch, title] of cases)
    assert.equal(historyTitle(opened, edit(opened, patch), films), title, JSON.stringify(patch));
});

test("undo and redo say what they will change; the timeline lists every step", () => {
  let history = historyReducer(initialHistory, { type: "load", edit: opened });
  assert.equal(undoTitle(history, films), "Undo");
  history = historyReducer(history, {
    type: "edit",
    patch: { lens: { ...opened.lens, amount: 0.5 } },
  });
  history = historyReducer(history, { type: "edit", patch: { stock: "portra400" } });
  history = historyReducer(history, { type: "undo" });
  assert.equal(undoTitle(history, films), "Undo Lens Correction");
  assert.equal(redoTitle(history, films), "Redo Portra 400");
  assert.deepEqual(editHistory(history, films), {
    titles: ["Opened", "Lens Correction", "Portra 400"],
    index: 1,
  });
});

test("going to a step keeps the whole timeline", () => {
  let history = historyReducer(initialHistory, { type: "load", edit: opened });
  for (const ev of [1, 2, 3])
    history = historyReducer(history, {
      type: "edit",
      patch: { params: { ...history.present.params, ev } },
    });
  const back = historyReducer(history, { type: "goTo", index: 0 });
  assert.equal(back.present, opened);
  assert.equal(back.past.length, 0);
  assert.equal(back.future.length, 3);
  const forward = historyReducer(back, { type: "goTo", index: 2 });
  assert.equal(forward.present.params.ev, 2);
  assert.deepEqual(editHistory(forward, films).titles, editHistory(history, films).titles);
  assert.equal(historyReducer(forward, { type: "goTo", index: 9 }), forward);
  assert.equal(historyReducer(forward, { type: "goTo", index: 2 }), forward);
});
