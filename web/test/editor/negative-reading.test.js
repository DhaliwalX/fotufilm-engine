import test from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { pixelSource } from "../../src/engine.js";
import {
  areaPreview,
  denseEnd,
  estimatedBorder,
  filmBase,
  plainReading,
  positiveSource,
} from "../../src/negative-reading.js";
import { rollBalance, rolledDenseEnd } from "../../src/negative-document.js";

// A scan of `width`×`height` linear RGBA, each pixel from `at(x, y)`.
function scan(width, height, at) {
  const data = new Float32Array(width * height * 4);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) data.set([...at(x, y), 1], (y * width + x) * 4);
  return pixelSource({ width, height, data });
}
const border = [0.8, 0.5, 0.25];
// Film `density` above the base in every channel, as a scanner reads it.
const film = (density) => border.map((v) => v * 10 ** -density);

test("the estimated base is the film passing the most light", () => {
  const source = scan(40, 30, (x) => (x < 4 ? border : film(1 + x / 40)));
  const estimate = estimatedBorder(source.read(0, 0, 40, 30));
  estimate.forEach((v, c) => assert.ok(Math.abs(v - border[c]) < 1e-6));
  assert.equal(estimatedBorder(new Float32Array(8)), null);
});

test("the densest end reads the central frame's highlights over the base", () => {
  // A dark holder at the edges stays out of the reading.
  const source = scan(50, 50, (x, y) =>
    x < 5 || y < 5 || x >= 45 || y >= 45 ? film(3) : film((x - 5) / 40),
  );
  const dense = denseEnd(border, source.read(0, 0, 50, 50), 50, 50);
  dense.forEach((v) => assert.ok(Math.abs(v - 39 / 40) < 1e-5, String(v)));
  assert.equal(denseEnd(border, new Float32Array(4 * 4), 1, 1), null);
});

test("picked clear film is the patch's median, and must be film", () => {
  const source = scan(160, 100, (x) => (x < 80 ? border : [0, 0, 0]));
  filmBase(source, [0.1, 0.5]).forEach((v, c) => assert.ok(Math.abs(v - border[c]) < 1e-6));
  assert.throws(() => filmBase(source, [0.9, 0.5]), /clear, unexposed film/);
});

test("readings draw a scan down by area, never past its own extremes", () => {
  // Hard-edged stripes, one bright pixel in three: each output pixel is their exact mean.
  const source = scan(30, 9, (x) => (x % 3 === 0 ? [0.9, 0.6, 0.3] : [0.1, 0.1, 0.1]));
  const { pixels, width, height } = areaPreview(source.read(0, 0, 30, 9), 30, 9, 10);
  assert.deepEqual([width, height], [10, 3]);
  for (let i = 0; i < pixels.length; i += 4)
    [0.9, 0.6, 0.3].forEach((v, c) => assert.ok(Math.abs(pixels[i + c] - (v + 0.2) / 3) < 1e-6));
  const small = scan(4, 4, () => border).read(0, 0, 4, 4);
  assert.equal(areaPreview(small, 4, 4).pixels, small);
});

// The scan preparation module, when tools/build-negative-wasm.sh has built it.
const prepared = new URL("../../public/negative/prepare.mjs", import.meta.url);
async function preparation() {
  const fetch = globalThis.fetch;
  globalThis.fetch = async (url) =>
    new Response(await readFile(new URL(url)), { headers: { "Content-Type": "application/wasm" } });
  try {
    const { default: create } = await import(prepared);
    return await create();
  } finally {
    globalThis.fetch = fetch;
  }
}

test("without a film a negative reads as a plain positive, its densest end diffuse white", {
  skip: !existsSync(prepared) && "build the scan preparation with tools/build-negative-wasm.sh",
}, async () => {
  // As Tests/FotufilmCoreTests/PlainNegativeScanTests.swift reads it.
  const gamma = 0.6,
    highlight = 0.18 * 5.656854;
  const dense = [1.2, 1.1, 0.88];
  const reading = plainReading(border, dense);
  assert.ok(Math.abs(reading.gains[0] - 1.1 / 1.2) < 1e-9);
  assert.ok(Math.abs(reading.gains[2] - 1.1 / 0.88) < 1e-9);
  const step = gamma * Math.log10(2);
  const source = positiveSource(
    scan(3, 1, (x) =>
      x === 0
        ? border.map((v, c) => v * 10 ** -dense[c])
        : x === 1
          ? border.map((v, c) => v * 10 ** -(dense[c] - step / reading.gains[c]))
          : [0, 0.2, 0.1],
    ),
    reading,
    await preparation(),
  );
  const light = source.read(0, 0, 3, 1);
  for (let c = 0; c < 3; c++) {
    assert.ok(Math.abs(light[c] - highlight) < 1e-4);
    assert.ok(Math.abs(light[4 + c] - highlight / 2) < 1e-4);
    assert.equal(light[8 + c], 0);
  }
  assert.equal(light[11], 1);
});

test("the plain reading balances on the densest end", () => {
  assert.deepEqual(plainReading(border, null), { border, gains: [1, 1, 1], reference: 1 });
  assert.deepEqual(plainReading(border, [0.1, 1, 3]).gains, [2, 1, 0.5]);
});

test("a roll's colour is the median of its frames' highlight colours", () => {
  // Three frames under one light, one filled by a sunset, and two too thin to read.
  const ends = [
    [0.9, 1.0, 1.2],
    [1.8, 2.0, 2.4],
    [1.35, 1.5, 1.8],
    [1.5, 1.0, 0.6],
    [0.01, 0.02, 0.03],
    null,
  ];
  const roll = rollBalance(ends);
  assert.equal(roll.frames, 4);
  // Medians of red/green {0.9, 0.9, 0.9, 1.5} and blue/green {1.2, 1.2, 1.2, 0.6}.
  assert.ok(Math.abs(roll.colour[0] - 0.9) < 1e-6, String(roll.colour[0]));
  assert.ok(Math.abs(roll.colour[1] - 1.2) < 1e-6, String(roll.colour[1]));
  // An even count takes the middle two.
  assert.deepEqual(rollBalance([[1, 1, 1], [2, 1, 3]]).colour, [1.5, 2]);
  assert.equal(rollBalance([[1, 1, 1]]), null);
  assert.equal(rollBalance([]), null);
});

test("a frame on its roll keeps its own green and takes the roll's colour", () => {
  const roll = { colour: [0.9, 1.2], frames: 4 };
  const rolled = rolledDenseEnd([1.5, 1.0, 0.6], roll);
  assert.deepEqual(rolled.map((v) => Number(v.toFixed(6))), [0.9, 1, 1.2]);
  // Without a roll, or a frame too thin to read, the frame reads as it is.
  assert.deepEqual(rolledDenseEnd([1.5, 1.0, 0.6], null), [1.5, 1.0, 0.6]);
  assert.deepEqual(rolledDenseEnd([1, 0.01, 1], roll), [1, 0.01, 1]);
  assert.equal(rolledDenseEnd(null, roll), null);
  // The plain reading balances a rolled frame on the roll: green held, red and blue scaled.
  const plain = plainReading([0.8, 0.5, 0.25], rolledDenseEnd([1.5, 1.0, 0.6], roll));
  assert.ok(Math.abs(plain.gains[0] - 1 / 0.9) < 1e-6);
  assert.ok(Math.abs(plain.gains[2] - 1 / 1.2) < 1e-6);
  assert.equal(plain.reference, 1);
});
