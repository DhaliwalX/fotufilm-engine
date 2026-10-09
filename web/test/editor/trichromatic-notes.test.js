import test from "node:test";
import assert from "node:assert/strict";
import { trichromaticNotes } from "../../src/editor/useDocumentActions.js";

test("a merge that left nothing out says nothing", () => {
  assert.equal(trichromaticNotes({ scans: [{ name: "a-rgb.tif" }] }), "");
});

test("frames not merged, blanks and white exposures are each named", () => {
  assert.equal(
    trichromaticNotes({
      failures: [{ sources: ["r.arw", "g.arw", "b.arw"], reason: "The exposures are not the same size." }],
      blanks: ["leader.arw"],
      others: ["white.arw", "white2.arw"],
    }),
    "r.arw, g.arw, b.arw: The exposures are not the same size. Left out as blank: leader.arw. " +
      "Left out, not under one light: white.arw, white2.arw.",
  );
});

test("repeated exposures and loosely lined-up scans are each named", () => {
  assert.equal(
    trichromaticNotes({ repeats: ["b5.arw"], loose: ["r7-rgb.tif"] }),
    "Left out, repeated by a later exposure: b5.arw. " +
      "Lined up loosely, so colours may fringe: r7-rgb.tif.",
  );
});
