import { decodeRGBA, imageSource } from "./engine.js";

// A bounded, scene-linear source for geometry. Ordinary photos are decoded in
// small tiles; full-resolution export never needs a second full-size float image.
export function linearSampler(image) {
  const width = image.naturalWidth,
    height = image.naturalHeight;
  const floating = image.linear || image.raw;
  let pixel;
  if (floating) {
    const { data, colors, sceneScale = 1, profile } = floating;
    const scale = image.linear ? 1 : sceneScale / 65535;
    pixel = (x, y, c) => {
      const i = (y * width + x) * colors;
      if (!profile) return data[i + (colors === 1 ? 0 : c)] * scale;
      // Transform camera RGB before sampling separate color planes. A chromatic
      // correction gives each output channel a different source coordinate.
      const m = profile.matrix,
        row = c * 3;
      return (
        (m[row] * data[i] +
          m[row + 1] * data[i + (colors === 1 ? 0 : 1)] +
          m[row + 2] * data[i + (colors === 1 ? 0 : 2)]) *
        scale
      );
    };
  } else {
    const source = imageSource(image),
      cache = new Map(),
      size = 128;
    pixel = (x, y, c) => {
      const tx = Math.floor(x / size) * size,
        ty = Math.floor(y / size) * size;
      const key = ty * width + tx;
      let tile = cache.get(key);
      if (!tile) {
        const w = Math.min(size, width - tx),
          h = Math.min(size, height - ty);
        tile = { width: w, data: decodeRGBA(source.read(tx, ty, w, h)) };
        cache.set(key, tile);
        if (cache.size > 64) cache.delete(cache.keys().next().value);
      }
      return tile.data[((y - ty) * tile.width + x - tx) * 4 + c];
    };
  }
  return (x, y, c) => {
    x = Math.max(0, Math.min(width - 1, x));
    y = Math.max(0, Math.min(height - 1, y));
    const ix = Math.floor(x),
      iy = Math.floor(y),
      fx = x - ix,
      fy = y - iy;
    const nx = Math.min(ix + 1, width - 1),
      ny = Math.min(iy + 1, height - 1);
    const a = pixel(ix, iy, c),
      b = pixel(nx, iy, c),
      d = pixel(ix, ny, c),
      e = pixel(nx, ny, c);
    return (a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy;
  };
}
