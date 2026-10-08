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
