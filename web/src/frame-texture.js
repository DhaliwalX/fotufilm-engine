// Same seeded value-noise field as the native filed carrier, in physical millimetres.
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
