import test from "node:test";
import assert from "node:assert/strict";
import {
  allStrip,
  chosenFiles,
  pressedStrip,
  stripStart,
} from "../../src/editor/strip-selection.js";

const files = ["a", "b", "c", "d", "e"].map((id) => ({
  id,
  name: `${id}.jpg`,
}));
const ids = (selection, activeId = "b") =>
  chosenFiles(files, activeId, selection).map((file) => file.id);

test("a plain click chooses the photo it shows, alone", () => {
  const pressed = pressedStrip(files, "b", allStrip(files, "b"), "d");
  // Until it is shown, only the photo shown before; then it alone.
  assert.deepEqual(ids(pressed, "b"), ["b"]);
  assert.deepEqual(ids(pressed, "d"), ["d"]);
});

test("Command-click adds and removes photos beside the one shown", () => {
  let selection = stripStart("b");
  selection = pressedStrip(files, "b", selection, "d", { toggle: true });
  assert.deepEqual(ids(selection), ["b", "d"]);
  selection = pressedStrip(files, "b", selection, "a", { toggle: true });
  assert.deepEqual(ids(selection), ["a", "b", "d"]);
  selection = pressedStrip(files, "b", selection, "d", { toggle: true });
  assert.deepEqual(ids(selection), ["a", "b"]);
});

test("the photo shown cannot be taken out", () => {
  const selection = pressedStrip(files, "b", stripStart("b"), "c", {
    toggle: true,
  });
  assert.deepEqual(
    ids(pressedStrip(files, "b", selection, "b", { toggle: true })),
    ["b", "c"],
  );
});

test("Shift-click chooses the run from the photo shown", () => {
  const selection = pressedStrip(files, "b", stripStart("b"), "e", {
    range: true,
  });
  assert.deepEqual(ids(selection), ["b", "c", "d", "e"]);
  const back = pressedStrip(files, "b", selection, "a", { range: true });
  assert.deepEqual(ids(back), ["a", "b"]);
});

test("Select All chooses every open photo", () => {
  assert.deepEqual(ids(allStrip(files, "b")), ["a", "b", "c", "d", "e"]);
});

test("closed photos drop out and the one shown is always there", () => {
  const selection = { selected: new Set(["gone", "c"]), anchor: "c" };
  assert.deepEqual(ids(selection, "a"), ["a", "c"]);
  assert.deepEqual(ids(stripStart(null), null), []);
});
