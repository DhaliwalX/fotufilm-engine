// The photo library's Halide thumbnail resampler, run in Node: area averaging in linear light,
// every EXIF orientation, and the cost of a typical thumbnail.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createResampler } from '../web/src/photo-library/thumbnail-resampler.js';

const assets = new URL('../web/public/library/', import.meta.url);
globalThis.fetch = async (url) => new Response(await readFile(new URL(url)), {
  headers: { 'Content-Type': 'application/wasm' },
});
const { default: create } = await import(new URL('thumbnail.mjs', assets));
const resample = createResampler(await create());

function image(width, height, colour) {
  const pixels = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) pixels.set([...colour(x, y), 255], (y * width + x) * 4);
  return pixels;
}
const at = (result, x, y) => [...result.pixels.subarray((y * result.width + x) * 4, (y * result.width + x) * 4 + 4)];

// A flat field stays exactly itself at any ratio, including non-integer ones.
for (const [w, h, edge] of [[640, 480, 160], [641, 479, 100], [37, 91, 13]]) {
  const flat = resample(image(w, h, () => [200, 90, 17]), w, h, edge);
  for (let i = 0; i < flat.pixels.length; i += 4)
    assert.deepEqual([...flat.pixels.subarray(i, i + 4)], [200, 90, 17, 255], `${w}x${h}→${edge}`);
}

// Black and white pixels average to half the light, which sRGB encodes as 188, not 128.
const checker = resample(image(64, 64, (x, y) => ((x + y) % 2 ? [255, 255, 255] : [0, 0, 0])), 64, 64, 16);
for (let i = 0; i < checker.pixels.length; i += 4) assert.ok(Math.abs(checker.pixels[i] - 188) <= 1);

// Upright quadrants: red top left, green top right, blue bottom left, white bottom right.
const quadrants = image(8, 4, (x, y) => (y < 2 ? (x < 4 ? [255, 0, 0] : [0, 255, 0]) : x < 4 ? [0, 0, 255] : [255, 255, 255]));
const R = [255, 0, 0, 255], G = [0, 255, 0, 255], B = [0, 0, 255, 255], W = [255, 255, 255, 255];
// Stored image → what the viewer should see after applying each EXIF orientation.
const expected = {
  1: [[R, G], [B, W]], 2: [[G, R], [W, B]], 3: [[W, B], [G, R]], 4: [[B, W], [R, G]],
  5: [[R, B], [G, W]], 6: [[B, R], [W, G]], 7: [[W, G], [B, R]], 8: [[G, W], [R, B]],
};
for (const [orientation, [top, bottom]] of Object.entries(expected)) {
  const o = Number(orientation);
  const result = resample(quadrants, 8, 4, 4, o);
  assert.deepEqual([result.width, result.height], o >= 5 ? [2, 4] : [4, 2], `shape ${o}`);
  const corner = (cx, cy) => at(result, cx ? result.width - 1 : 0, cy ? result.height - 1 : 0);
  assert.deepEqual([corner(0, 0), corner(1, 0)], top, `orientation ${o} top`);
  assert.deepEqual([corner(0, 1), corner(1, 1)], bottom, `orientation ${o} bottom`);
}

const source = image(960, 640, (x, y) => [x & 255, y & 255, (x ^ y) & 255]);
resample(source, 960, 640, 480);
const start = performance.now();
for (let i = 0; i < 20; i++) resample(source, 960, 640, 480, 6);
console.log(`library thumbnail: 960x640 → 320x480 in ${((performance.now() - start) / 20).toFixed(2)} ms`);
console.log('Library thumbnail resampler passed.');
