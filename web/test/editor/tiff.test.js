import test from "node:test";
import assert from "node:assert/strict";
import { encodeTiff16 } from "../../src/tiff.js";
import { encodeTileInto } from "../../src/engine.js";
import { compositeSelection } from "../../src/selective.js";

export function readTiff(buffer) {
  const view = new DataView(buffer),
    tags = new Map();
  assert.equal(view.getUint16(0, true), 0x4949);
  assert.equal(view.getUint16(2, true), 42);
  const ifd = view.getUint32(4, true),
    count = view.getUint16(ifd, true);
  for (let i = 0; i < count; i++) {
    const at = ifd + 2 + i * 12,
      type = view.getUint16(at + 2, true),
      length = view.getUint32(at + 4, true);
    const step = type === 3 ? 2 : type === 4 ? 4 : 1;
    const start = length * step > 4 ? view.getUint32(at + 8, true) : at + 8;
    tags.set(
      view.getUint16(at, true),
      Array.from({ length }, (_, j) =>
        step === 2
          ? view.getUint16(start + j * step, true)
          : step === 4
            ? view.getUint32(start + j * step, true)
            : view.getUint8(start + j),
      ),
    );
  }
  const pixels = tags
    .get(273)
    .flatMap((start, i) =>
      Array.from({ length: tags.get(279)[i] / 2 }, (_, j) =>
        view.getUint16(start + j * 2, true),
      ),
    );
  return { tags, pixels };
}
test("16-bit TIFF preserves samples across strips, alpha and embedded sRGB profile", async () => {
  for (const height of [1, 67]) {
    const width = 3,
      pixels = Uint16Array.from(
        { length: width * height * 4 },
        (_, i) => (i * 79 + 123) % 65536,
      );
    const blob = encodeTiff16({ pixels, width, height });
    assert.equal(blob.type, "image/tiff");
    const output = readTiff(await blob.arrayBuffer());
    assert.deepEqual(output.pixels, Array.from(pixels));
    assert.deepEqual(output.tags.get(258), [16, 16, 16, 16]);
    assert.deepEqual(output.tags.get(338), [2]);
    assert.equal(
      String.fromCharCode(...output.tags.get(34675).slice(36, 40)),
      "acsp",
    );
    assert.deepEqual(output.tags.get(256), [width]);
    assert.deepEqual(output.tags.get(257), [height]);
  }
  assert.throws(
    () => encodeTiff16({ pixels: new Uint8Array(4), width: 1, height: 1 }),
    /Invalid/,
  );
});
test("float print encoding retains more than 256 levels without 8-bit quantization", () => {
  const width = 2048,
    output = new Float32Array(width * 4),
    pixels = new Uint16Array(width * 4);
  for (let x = 0; x < width; x++)
    for (let c = 0; c < 3; c++) output[x * 4 + c] = x / (width - 1);
  encodeTileInto(
    pixels,
    width,
    output,
    { x: 0, y: 0, width, height: 1, region: { x: 0, y: 0, width, height: 1 } },
    0,
    4,
    [0, 1, 2],
  );
  assert.ok(
    new Set(Array.from(pixels).filter((_, i) => i % 4 === 0)).size > 1800,
  );
  assert.ok(pixels.some((v, i) => i % 4 !== 3 && v % 257 !== 0));
  assert.equal(pixels[3], 65535);
  output.fill(NaN);
  encodeTileInto(
    pixels,
    width,
    output,
    { x: 0, y: 0, width, height: 1, region: { x: 0, y: 0, width, height: 1 } },
    0,
    4,
    [0, 1, 2],
  );
  assert.equal(pixels[0], 0);
});
test("selective composition retains original 16-bit samples at mask endpoints", async () => {
  const source = {
    width: 2,
    height: 1,
    read: () => new Float32Array([0.3, 0.1, 0.1, 1, 0.1, 0.5, 0.8, 1]),
  };
  const ground = new Uint16Array([
    123, 456, 789, 65535, 1234, 5678, 9012, 65535,
  ]);
  const local = new Uint16Array([
    1123, 1456, 1789, 65535, 2234, 6678, 10012, 65535,
  ]);
  const result = await compositeSelection(source, ground, local, {
    kind: "color",
    sample: [0.3, 0.1, 0.1],
    range: 0.1,
    softness: 0.5,
  });
  assert.ok(result instanceof Uint16Array);
  assert.deepEqual(result.slice(0, 4), local.slice(0, 4));
  assert.deepEqual(result.slice(4), ground.slice(4));
});
