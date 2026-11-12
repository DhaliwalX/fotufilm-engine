import test from "node:test";
import assert from "node:assert/strict";
import { TONE_CURVE_STEPS, rampCurve, toneRamp } from "../../src/tone-curve.js";

test("the ramp holds each input code across its step on every row", () => {
  const ramp = toneRamp();
  assert.equal(ramp.width, TONE_CURVE_STEPS * 4);
  const pixels = ramp.read(0, 0, ramp.width, ramp.height);
  assert.ok(pixels instanceof Uint8ClampedArray);
  for (const x of [0, 3, 4, 513, ramp.width - 1]) {
    const i = ((ramp.height - 1) * ramp.width + x) * 4;
    assert.deepEqual([...pixels.subarray(i, i + 4)], [x >> 2, x >> 2, x >> 2, 255]);
  }
  assert.deepEqual([...ramp.read(8, 1, 1, 1)], [2, 2, 2, 255]);
});

test("an untouched ramp reads back as the identity curve", () => {
  const ramp = toneRamp();
  const curve = rampCurve(ramp.read(0, 0, ramp.width, ramp.height));
  for (const channel of [curve.red, curve.green, curve.blue]) {
    assert.equal(channel.length, TONE_CURVE_STEPS);
    channel.forEach((v, code) => assert.ok(Math.abs(v - code / 255) < 1e-9));
  }
});

test("each step is read inside its edges, so a neighbour's bleed does not count", () => {
  const ramp = toneRamp();
  const pixels = ramp.read(0, 0, ramp.width, ramp.height).slice();
  // Corrupt the outer pixels of step 10 on every row.
  for (let y = 0; y < ramp.height; ++y)
    for (const x of [40, 43]) pixels.fill(0, (y * ramp.width + x) * 4, (y * ramp.width + x) * 4 + 3);
  assert.equal(rampCurve(pixels).green[10], 10 / 255);
});
