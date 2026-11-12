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
  pickedNeutral,
  plainReading,
  plainCrosstalk,
  PLAIN_CROSSTALK,
  positiveSource,
  tonalSlopes,
} from "../../src/negative-reading.js";
import {
  newNegative,
  parseNegative,
  readingRequest,
  readsModel,
  rollBalance,
  rolledDenseEnd,
} from "../../src/negative-document.js";
import { NEGATIVE } from "../../src/engine-constants.js";

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
  // Something neutral in the picture is picked the same way, and says so where it cannot be.
  pickedNeutral(source, [0.1, 0.5]).forEach((v, c) => assert.ok(Math.abs(v - border[c]) < 1e-6));
  assert.throws(() => pickedNeutral(source, [0.9, 0.5]), /grey or white in the picture/);
});

test("a frame's tonal steps say how red and blue rise against green", () => {
  // Steps of 0.15 in green every five pixels, red rising 0.8 and blue 1.2 times as far, inside
  // a dark holder.
  const stepped = scan(200, 100, (x, y) => {
    if (x < 10 || y < 5 || x >= 190 || y >= 95) return film(3);
    const green = 0.2 + Math.floor(x / 5) * 0.15;
    return border.map((v, c) => v * 10 ** -(green * [0.8, 1, 1.2][c]));
  });
  const slopes = tonalSlopes(border, stepped.read(0, 0, 200, 100), 200, 100);
  assert.ok(Math.abs(slopes[0] - 0.8) < 1e-3, String(slopes[0]));
  assert.ok(Math.abs(slopes[1] - 1.2) < 1e-3, String(slopes[1]));
  // A frame without steps, one too small, and a base that is no film say nothing.
  const flat = scan(200, 100, () => film(1));
  assert.equal(tonalSlopes(border, flat.read(0, 0, 200, 100), 200, 100), null);
  assert.equal(tonalSlopes(border, new Float32Array(4), 1, 1), null);
  assert.equal(tonalSlopes([0.8, 0, 0.25], stepped.read(0, 0, 200, 100), 200, 100), null);
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
  assert.deepEqual(plainReading(border, null), {
    border,
    gains: [1, 1, 1],
    reference: 1,
    weights: [
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ],
  });
  assert.deepEqual(plainReading(border, [0.1, 1, 3]).gains, [2, 1, 0.5]);
});

test("the plain reading undoes crosstalk as PlainNegativeScan does", () => {
  const near = (a, b, tolerance = 1e-5) => assert.ok(Math.abs(a - b) < tolerance, `${a} ≠ ${b}`);
  // Without a frame to keep, rows blend from each channel alone to the full correction and sum
  // to one, so equal densities stay equal.
  for (const light of ["white", "rgb"]) {
    const full = plainCrosstalk(1, light),
      half = plainCrosstalk(0.5, light);
    for (let r = 0; r < 3; r++) {
      near(full[r].reduce((a, b) => a + b), 1);
      for (let c = 0; c < 3; c++) {
        near(full[r][c], PLAIN_CROSSTALK[light][r][c]);
        near(half[r][c], ((r === c ? 1 : 0) + full[r][c]) / 2, 1e-6);
      }
    }
  }
  assert.deepEqual(plainCrosstalk(5), plainCrosstalk(1));
  // The frame's densest end reads as it did, so its balance is the frame's own.
  const dense = [1.0, 1.3, 1.1];
  const weights = plainCrosstalk(1, "white", dense);
  for (let r = 0; r < 3; r++)
    near(weights[r].reduce((sum, w, c) => sum + w * dense[c], 0), dense[r]);
  const muted = plainReading(border, dense),
    separated = plainReading(border, dense, 1);
  for (let c = 0; c < 3; c++) near(separated.gains[c], muted.gains[c]);
  near(separated.reference, muted.reference);
  // Red, green and blue LEDs leave far less to undo than white light.
  const off = (w) => w[0][1] ** 2 + w[0][2] ** 2 + w[1][0] ** 2 + w[1][2] ** 2 + w[2][0] ** 2 + w[2][1] ** 2;
  assert.ok(off(plainCrosstalk(1, "rgb")) < 0.01 * off(plainCrosstalk(1, "white")));
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
  const measures = ends.map((denseEnd) => ({ denseEnd }));
  const roll = rollBalance(measures);
  assert.equal(roll.frames, 4);
  // Medians of red/green {0.9, 0.9, 0.9, 1.5} and blue/green {1.2, 1.2, 1.2, 0.6}.
  assert.ok(Math.abs(roll.colour[0] - 0.9) < 1e-6, String(roll.colour[0]));
  assert.ok(Math.abs(roll.colour[1] - 1.2) < 1e-6, String(roll.colour[1]));
  // Its level is the median green of those ends, and with their colour its neutral.
  assert.ok(Math.abs(roll.level - 1.25) < 1e-6, String(roll.level));
  // An even count takes the middle two.
  assert.deepEqual(
    rollBalance([{ denseEnd: [1, 1, 1] }, { denseEnd: [2, 1, 3] }]).colour,
    [1.5, 2],
  );
  assert.equal(rollBalance([{ denseEnd: [1, 1, 1] }]), null);
  assert.equal(rollBalance([]), null);

  // How steep its records read comes from six frames' tonal steps or more, never fewer.
  assert.equal(roll.slopes, undefined);
  const steps = [
    [0.8, 1.1],
    [0.9, 1.2],
    [1.0, 1.3],
    [0.85, 1.25],
    [0.95, 1.15],
    [0.9, 1.2],
  ];
  const stepped = steps.map((slopes, i) => ({ denseEnd: ends[i % 3], slopes }));
  assert.equal(rollBalance(stepped.slice(0, 5)).slopes, undefined);
  const contrast = rollBalance([...stepped, { denseEnd: ends[0], slopes: [NaN, 1] }, null]);
  assert.ok(Math.abs(contrast.slopes[0] - 0.9) < 1e-6);
  assert.ok(Math.abs(contrast.slopes[1] - 1.2) < 1e-6);
  assert.equal(contrast.frames, 7);
});

test("a new negative is read with the current reading, an older one as it was", () => {
  const fresh = newNegative("screen");
  assert.equal(fresh.reading, NEGATIVE.currentReading);
  assert.equal(fresh.crosstalk, 1);
  assert.ok(readsModel(fresh));
  assert.deepEqual(parseNegative(fresh), fresh);
  const first = { border: null, lightFrame: null, roll: null, crosstalk: 0.4, scanLight: "rgb" };
  assert.ok(!readsModel(first));
  assert.deepEqual(parseNegative(first), first);
  assert.deepEqual(newNegative("white", 1), { ...first, crosstalk: 0, scanLight: "white" });

  // What the current reading keeps crosses a save and back.
  const kept = {
    ...fresh,
    border: [0.8, 0.5, 0.25],
    roll: { colour: [0.9, 1.2], frames: 7, level: 1.25, slopes: [0.9, 1.2] },
    camera: "scanner",
    balance: "roll",
    neutral: [0.2, 0.1, 0.05],
  };
  assert.deepEqual(parseNegative(kept), kept);
  for (const change of [
    { reading: 0 },
    { camera: "" },
    { balance: "page" },
    { neutral: [0.2, 0.1] },
    { neutral: [0.2, 0, 0.05] },
    { scanLight: "uv" },
    { roll: { colour: [0.9, 1.2], frames: 7, slopes: [0.9, -1] } },
    { roll: { colour: [0.9, 1.2], frames: 7, level: 0 } },
  ])
    assert.throws(() => parseNegative({ ...kept, ...change }), /Invalid negative reading/);
});

test("a request says of a reading what its edit keeps and its frame measures", () => {
  const measured = { border, dense: [1.5, 1.0, 0.6], slopes: [0.9, 1.2] };
  const roll = { colour: [0.9, 1.2], frames: 4, level: 1.25 };
  // The first reading: the frame's densest end on its roll's colour, as before.
  const first = readingRequest(
    { border: null, lightFrame: null, roll, crosstalk: 0.4, scanLight: "rgb" },
    measured,
    { camera: { make: "SONY", model: "ILCE-7CM2" } },
  );
  assert.deepEqual(Object.keys(first), ["border", "denseEnd", "crosstalk", "scanLight"]);
  assert.deepEqual(first.denseEnd.map((v) => Number(v.toFixed(6))), [0.9, 1, 1.2]);
  assert.deepEqual([first.border, first.crosstalk, first.scanLight], [border, 0.4, "rgb"]);
  assert.deepEqual(readingRequest({ roll: null }, measured), {
    border,
    denseEnd: measured.dense,
    crosstalk: 0,
    scanLight: "white",
  });

  // The current one: the frame's own densest end, the roll beside it, and the scan's source.
  const source = { camera: { make: "SONY", model: "ILCE-7CM2" }, kelvin: 5100 };
  const current = readingRequest(
    { ...newNegative("screen"), roll, balance: "roll", neutral: [0.2, 0.1, 0.05], lightFrame: "a" },
    measured,
    source,
  );
  assert.deepEqual(current, {
    border,
    denseEnd: measured.dense,
    reading: NEGATIVE.currentReading,
    crosstalk: 1,
    scanLight: "screen",
    balance: "roll",
    neutral: [0.2, 0.1, 0.05],
    roll,
    source,
  });
  // A scan whose file says nothing sends no source, and an edit only what it keeps.
  assert.deepEqual(readingRequest({ reading: 2, roll: null }, { border, dense: null }), {
    border,
    denseEnd: null,
    reading: 2,
  });
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
