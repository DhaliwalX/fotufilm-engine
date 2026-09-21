import { yieldToBrowser } from "./yield.js";

// Same seeded value-noise field as EmulsionBorderRenderer. Coordinates are physical
// millimetres for carrier filing, and 1/1000 of the photograph's short side for emulsion.
export function frameNoise(x, y, seed) {
  const ix = Math.floor(x),
    iy = Math.floor(y),
    fx = x - ix,
    fy = y - iy;
  const u = fx * fx * (3 - 2 * fx),
    v = fy * fy * (3 - 2 * fy);
  const sample = (a, b) => {
    let n =
      (Math.imul(a, 374761393) +
        Math.imul(b, 668265263) +
        Math.imul(seed, 1013904223)) >>>
      0;
    n = Math.imul(n ^ (n >>> 13), 1274126177) >>> 0;
    n ^= n >>> 16;
    return (n & 65535) / 32767.5 - 1;
  };
  const a = sample(ix, iy),
    b = sample(ix + 1, iy),
    c = sample(ix, iy + 1),
    d = sample(ix + 1, iy + 1);
  return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v;
}
const smooth = (low, high, value) => {
  const t = Math.max(0, Math.min(1, (value - low) / (high - low)));
  return t * t * (3 - 2 * t);
};
const bump = (v, centre, radius) => 1 - smooth(0, radius, Math.abs(v - centre));
export const emulsionRim = 0.045;

export async function emulsionTexture(
  photoWidth,
  photoHeight,
  stale = () => false,
) {
  const unit = Math.min(photoWidth, photoHeight) / 1000;
  const w = photoWidth / unit,
    h = photoHeight / unit,
    fringe = 58,
    reach = emulsionRim * 1000;
  const step = Math.max(1, (Math.max(w, h) + 2 * fringe) / 2048);
  const width = Math.ceil((w + 2 * fringe) / step),
    height = Math.ceil((h + 2 * fringe) / step);
  const bytes = new Uint8ClampedArray(width * height * 4);
  for (let row = 0; row < height; row++) {
    if (row % 32 === 0) {
      await yieldToBrowser();
      if (stale()) return null;
    }
    const y = h / 2 + fringe - (row + 0.5) * step;
    for (let column = 0; column < width; column++) {
      const x = (column + 0.5) * step - fringe - w / 2;
      if (Math.abs(x) < w / 2 - reach && Math.abs(y) < h / 2 - reach) continue;
      const qx = Math.abs(x) - w / 2 - 32 + 23,
        qy = Math.abs(y) - h / 2 - 32 + 23;
      const distance =
        Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) +
        Math.min(Math.max(qx, qy), 0) -
        23;
      if (distance > 23) continue;
      const coarse = frameNoise(x * 0.014, y * 0.014, 31),
        tooth = frameNoise(x * 0.14, y * 0.14, 97);
      const fine = frameNoise(x * 0.71, y * 0.71, 211),
        d = distance - 7 * coarse - 2.2 * tooth;
      const solid = 1 - smooth(-2, 1.5, d);
      const residue =
        (1 - smooth(-3, 15, d)) * smooth(-0.75, 0.8, tooth * 0.7 + fine * 0.75);
      const wear = smooth(-9, 2, d) * Math.max(0, fine + tooth * 0.45) * 0.53;
      const bite = 15 * coarse + 5 * tooth + 1.5 * fine;
      const fade = smooth(-reach - bite * 0.5, -5 - bite, distance + 32);
      const alpha =
        Math.min(1, Math.max(solid * (1 - wear), residue * 0.8)) * fade;
      if (alpha < 0.004) continue;
      const position = (y + h / 2) / h,
        left = 1 - smooth(-w / 2 - 8, -w / 2 + 15, x);
      const patches =
        bump(position, 0.88, 0.035) +
        bump(position, 0.68, 0.024) +
        bump(position, 0.39, 0.018) +
        bump(position, 0.035, 0.035);
      const rust = Math.min(1, patches * left * smooth(-17, -1, d)),
        grain = fine * 2.4 + coarse * 1.4;
      // Canvas ImageData is straight-alpha. The native texture uses premultiplied storage.
      const i = (row * width + column) * 4;
      bytes.set(
        [
          13 + grain + rust * 51,
          23 + grain + rust * 9,
          24 + grain - rust * 6,
          alpha * 255,
        ],
        i,
      );
    }
  }
  return { bytes, width, height, unit, step, fringe };
}
