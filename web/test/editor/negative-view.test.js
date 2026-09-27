import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit } from "../../src/editor-state.js";
import { canShowNegative, negativeViewEdit } from "../../src/negative-view.js";

const colourNegative = {
  id: "gold200",
  defaultMedium: "screen",
  media: [{ id: "screen" }, { id: "negative" }, { id: "ra4" }],
};
const slide = { id: "e100", defaultMedium: "screen", media: [{ id: "screen" }] };

test("Show Negative develops the negative without touching the edit", () => {
  const edit = defaultEdit("gold200");
  assert.equal(canShowNegative(edit, colourNegative), true);
  assert.equal(negativeViewEdit(edit, colourNegative, true).medium, "negative");
  assert.equal(negativeViewEdit(edit, colourNegative, false), edit);
  assert.equal(edit.medium, null);
});

test("a slide, no film, or a negative medium already chosen has nothing to show", () => {
  assert.equal(canShowNegative(defaultEdit("e100"), slide), false);
  assert.equal(canShowNegative(defaultEdit(null), colourNegative), false);
  const negative = { ...defaultEdit("gold200"), medium: "negative" };
  assert.equal(canShowNegative(negative, colourNegative), false);
  assert.equal(negativeViewEdit(negative, colourNegative, true), negative);
});
