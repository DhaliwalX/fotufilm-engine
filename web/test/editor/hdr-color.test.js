import test from "node:test";
import assert from "node:assert/strict";
import {
  halfFloat,
  decodeHDRPixels,
  referenceGain,
  calibrateHDR,
} from "../../src/hdr-color.js";
import { defaultEdit, parseEdit } from "../../src/editor-state.js";
import { interpretedImage } from "../../src/source-interpretation.js";

test("half-float import preserves highlights, signs and subnormals", () => {
  assert.equal(halfFloat(0x4000), 2);
  assert.equal(halfFloat(0xbc00), -1);
  assert.equal(halfFloat(1), 2 ** -24);
  assert.equal(halfFloat(0x7c00), Infinity);
  assert.ok(Number.isNaN(halfFloat(0x7e00)));
});

test("HDR ingest preserves white and converts all supported primaries without clipping", () => {
  const half = new Uint16Array([0x4000, 0x4000, 0x4000, 0x3c00]);
  for (const gamut of [0, 1, 2]) {
    const { pixels } = decodeHDRPixels(half, 1, 1, 1, gamut);
    assert.deepEqual([...pixels], [2, 2, 2, 1]);
  }
  const red = decodeHDRPixels(
    new Uint16Array([0x4000, 0, 0, 0x3c00]),
    1,
    1,
    1,
    1,
  ).pixels;
  assert.ok(red[0] > 1.5 && red[2] < 0);
  assert.throws(() => decodeHDRPixels(half, 1, 1, 1, -1), /primaries/);
});

test("all EXIF orientations preserve every pixel and respect row padding", () => {
  const half = new Uint16Array([
    0x3c00, 0, 0, 0, 0x4000, 0, 0, 0, 0, 0, 0, 0, 0x4200, 0, 0, 0, 0x4400, 0, 0,
    0, 0, 0, 0, 0, 0x4500, 0, 0, 0, 0x4600, 0, 0, 0, 0, 0, 0, 0,
  ]);
  const expected = [
    [1, 2, 3, 4, 5, 6],
    [2, 1, 4, 3, 6, 5],
    [6, 5, 4, 3, 2, 1],
    [5, 6, 3, 4, 1, 2],
    [1, 3, 5, 2, 4, 6],
    [5, 3, 1, 6, 4, 2],
    [6, 4, 2, 5, 3, 1],
    [2, 4, 6, 1, 3, 5],
  ];
  for (let orientation = 1; orientation <= 8; orientation++) {
    const result = decodeHDRPixels(half, 2, 3, 3, 2, orientation);
    assert.deepEqual(
      [...result.pixels].filter((_, i) => i % 4 === 0),
      expected[orientation - 1],
    );
    assert.equal(result.width, orientation < 5 ? 2 : 3);
  }
});

test("exposure placement ignores the SDR shoulder, rejects sparse pairs and never brightens", () => {
  const pixels = (value, count = 100) =>
    Float32Array.from({ length: count * 4 }, (_, i) =>
      i % 4 === 3 ? 1 : value,
    );
  assert.ok(Math.abs(referenceGain(pixels(0.36), pixels(0.18)) - 0.5) < 1e-6);
  assert.equal(referenceGain(pixels(4), pixels(0.18)), 0.25);
  assert.equal(referenceGain(pixels(0.1), pixels(0.18)), 1);
  assert.equal(referenceGain(pixels(4), pixels(0.9)), 1);
  assert.equal(referenceGain(pixels(0.36, 7), pixels(0.18, 7)), 1);
  const scene = pixels(0.36),
    reference = pixels(0.18);
  scene[0] = scene[1] = scene[2] = 4;
  reference[0] = reference[1] = reference[2] = 0.9;
  const gain = calibrateHDR(
    { pixels: scene, width: 10, height: 10 },
    { pixels: reference, width: 10, height: 10 },
  );
  assert.ok(Math.abs(gain - 0.5) < 1e-6);
  assert.equal(scene[0], 2);
  assert.equal(scene[3], 1);
});

test("source interpretation round-trips, defaults old edits, rejects invalid values and leaves RAW linear", () => {
  const edit = defaultEdit(),
    saved = (value) => JSON.stringify({ version: 1, edit: value });
  for (const sourceInterpretation of [
    "automatic",
    "fullRange",
    "standardRange",
  ])
    assert.equal(
      parseEdit(saved({ ...edit, sourceInterpretation }), [])
        .sourceInterpretation,
      sourceInterpretation,
    );
  delete edit.sourceInterpretation;
  assert.equal(parseEdit(saved(edit), []).sourceInterpretation, "automatic");
  assert.throws(
    () => parseEdit(saved({ ...edit, sourceInterpretation: "bogus" }), []),
    /interpretation/,
  );
  const standardImage = {},
    hdr = { standardImage },
    raw = { raw: {}, standardImage };
  assert.equal(interpretedImage(hdr, "standardRange"), standardImage);
  assert.equal(interpretedImage(hdr, "automatic"), hdr);
  assert.equal(interpretedImage(raw, "standardRange"), raw);
});
