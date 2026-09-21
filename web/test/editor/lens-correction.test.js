import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit, parseEdit } from "../../src/editor-state.js";
import {
  defaultLens,
  lensIsActive,
  readLensTable,
} from "../../src/lens-correction.js";
import { rawSource } from "../../src/raw-source.js";

const table = (r = 1, g = 1, b = 1, gain = 1) =>
  Float32Array.from({ length: 4096 }, (_, i) => [r, g, b, gain][i % 4]);
const frame = () => ({
  naturalWidth: 8,
  naturalHeight: 6,
  linear: {
    colors: 4,
    data: Float32Array.from({ length: 8 * 6 * 4 }, (_, i) =>
      i % 4 === 3 ? 1 : i / 4 / 8 - 2,
    ),
  },
});

test("lens edits validate, preserve disabled values and remain compatible with old saves", () => {
  const edit = {
    ...defaultEdit(),
    lens: { ...defaultLens(), distortion: 0.4 },
  };
  const parse = (edit) => parseEdit(JSON.stringify({ version: 1, edit }), []);
  assert.deepEqual(parse(edit).lens, edit.lens);
  assert.equal(lensIsActive(edit.lens), false);
  assert.equal(lensIsActive({ ...edit.lens, enabled: true }), true);
  delete edit.lens;
  assert.deepEqual(parse(edit).lens, defaultLens());
  for (const lens of [
    { ...defaultLens(), enabled: 1 },
    { ...defaultLens(), distortion: 1.1 },
    { enabled: true },
  ]) {
    assert.throws(() => parse({ ...edit, lens }), /Invalid lens/);
  }
  assert.throws(() => readLensTable(new ArrayBuffer(4)), /Invalid lens/);
  const invalid = table();
  invalid[0] = NaN;
  assert.throws(() => readLensTable(invalid.buffer), /Invalid lens/);
});

test("identity correction preserves HDR, negatives and every crop/rotate/flip geometry", () => {
  for (const rotation of [0, 1, 2, 3])
    for (const flip of [false, true])
      for (const crop of [
        defaultEdit().crop,
        [
          [0.25, 0],
          [1, 0],
          [1, 1],
          [0.25, 1],
        ],
      ]) {
        const edit = { ...defaultEdit(), rotation, flip, crop, straighten: 3 };
        const source = rawSource(frame(), edit, Infinity, false, table());
        const baseline = rawSource(frame(), edit);
        const expected = baseline.read(0, 0, baseline.width, baseline.height);
        const actual = source.read(0, 0, source.width, source.height);
        assert.equal(actual.length, expected.length);
        actual.forEach((v, i) => assert.ok(Math.abs(v - expected[i]) < 1e-6));
        assert.ok(Math.min(...actual) < 0);
        assert.ok(Math.max(...actual) > 1);
      }
});

test("lens warp precedes crop and tile boundaries cannot alter the correction", () => {
  const correction = table(0.96, 0.98, 1.02, 1.7),
    image = frame();
  const full = rawSource(image, defaultEdit(), Infinity, false, correction);
  const cropped = rawSource(
    image,
    {
      ...defaultEdit(),
      crop: [
        [0.25, 0],
        [1, 0],
        [1, 1],
        [0.25, 1],
      ],
    },
    Infinity,
    false,
    correction,
  );
  assert.deepEqual(cropped.read(0, 0, 6, 6), full.read(2, 0, 6, 6));
  const all = full.read(0, 0, 8, 6);
  assert.deepEqual(
    [...full.read(0, 0, 8, 3), ...full.read(0, 3, 8, 3)],
    [...all],
  );
});

test("camera RGB is transformed before chromatic channels sample different positions", () => {
  const image = frame(),
    data = new Uint16Array(8 * 6 * 3),
    matrix = [0.6, 0.3, 0.1, 0.2, 0.7, 0.1, 0.1, 0.3, 0.6];
  data.forEach((_, i) => {
    data[i] = (i * 379) % 65535;
  });
  const raw = {
    naturalWidth: 8,
    naturalHeight: 6,
    raw: { data, colors: 3, sceneScale: 3, profile: { matrix } },
  };
  for (let i = 0; i < 48; i++)
    for (let c = 0; c < 3; c++) {
      image.linear.data[i * 4 + c] = matrix
        .slice(c * 3, c * 3 + 3)
        .reduce((sum, m, k) => sum + (m * data[i * 3 + k] * 3) / 65535, 0);
    }
  const correction = table(0.9, 1, 1.1, 1.2);
  const actual = rawSource(
    raw,
    defaultEdit(),
    Infinity,
    false,
    correction,
  ).read(0, 0, 8, 6);
  const expected = rawSource(
    image,
    defaultEdit(),
    Infinity,
    false,
    correction,
  ).read(0, 0, 8, 6);
  actual.forEach((v, i) => assert.ok(Math.abs(v - expected[i]) < 1e-6));
});

test("profile selection and Amount survive saved edits and validate on load", () => {
  const edit = {
    ...defaultEdit(),
    lens: {
      ...defaultLens(),
      enabled: true,
      profileID: "synthetic",
      amount: 0.42,
    },
  };
  const parse = (value) =>
    parseEdit(
      JSON.stringify({ version: 1, edit: { ...edit, lens: value } }),
      [],
    );
  assert.deepEqual(parse(edit.lens).lens, edit.lens);
  for (const value of [
    { ...edit.lens, amount: -0.1 },
    { ...edit.lens, amount: 1.1 },
    { ...edit.lens, profileID: 3 },
  ])
    assert.throws(() => parse(value), /Invalid lens/);
});
