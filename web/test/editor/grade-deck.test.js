import test from "node:test";
import assert from "node:assert/strict";
import {
  capsuleLevel,
  gradeCast,
  gradeIsNeutral,
  gradeReadout,
  padBalance,
  padPoint,
  padReading,
} from "../../src/grade-deck.js";

test("a balance reads as the Mac app's deck names it", () => {
  assert.equal(gradeCast(0.4, 0), "Warm");
  assert.equal(gradeCast(0, -0.2), "Magenta");
  assert.equal(gradeCast(-0.5, 0.2), "Cool green");
  assert.equal(gradeCast(0.1, -0.3), "Magenta warm");
  assert.equal(padReading(0, 0), "Neutral");
  assert.equal(gradeReadout({ warmth: 0.3, tint: 0.1, level: -0.25 }), "Warm green · -25");
  assert.equal(gradeReadout({ level: 0.5 }), "+50");
  assert.equal(gradeReadout({}), "");
});

test("the pad puts green up and warm right, snapping to neutral near the ring", () => {
  // A 236 x 168 pad, 18 in from its edges.
  assert.deepEqual(padBalance(236 - 18, 18, 236, 168), { warmth: 1, tint: 1 });
  assert.deepEqual(padBalance(0, 168, 236, 168), { warmth: -1, tint: -1 });
  assert.deepEqual(padBalance(118 + 5, 84 - 3, 236, 168), { warmth: 0, tint: 0 });
  const balance = padBalance(118 + 50, 84 + 33, 236, 168);
  assert.ok(Math.abs(balance.warmth - 0.5) < 1e-9 && Math.abs(balance.tint + 0.5) < 1e-9);
  assert.deepEqual(padPoint(0.5, -0.5, 236, 168), { x: 168, y: 117 });
});

test("the level capsule runs -1 to +1 across, snapping to neutral in its well", () => {
  assert.equal(capsuleLevel(0, 240, 24), -1);
  assert.equal(capsuleLevel(240, 240, 24), 1);
  assert.equal(capsuleLevel(122, 240, 24), 0);
  assert.equal(capsuleLevel(12 + 216 * 0.75, 240, 24), 0.5);
});

test("Reset Grade has nothing to do on a neutral grade", () => {
  assert.equal(gradeIsNeutral({ ev: 1 }), true);
  assert.equal(gradeIsNeutral({ gradeMidtonesTint: 0.1 }), false);
});
