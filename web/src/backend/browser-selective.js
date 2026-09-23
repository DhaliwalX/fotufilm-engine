import { yieldToBrowser } from "../yield.js";
import { decodeRGBA } from "../engine.js";
import { selectionWeight } from "../selective.js";

export function sampleScene(source, point) {
  const x = Math.min(
    source.width - 1,
    Math.max(0, Math.floor(point[0] * source.width)),
  );
  const y = Math.min(
    source.height - 1,
    Math.max(0, Math.floor(point[1] * source.height)),
  );
  const left = Math.max(0, x - 2),
    top = Math.max(0, y - 2);
  const width = Math.min(source.width, x + 3) - left;
  const height = Math.min(source.height, y + 3) - top;
  const pixels = decodeRGBA(source.read(left, top, width, height));
  const sample = [0, 0, 0];
  let weight = 0;
  for (let i = 0; i < pixels.length; i += 4) {
    weight += pixels[i + 3];
    for (let c = 0; c < 3; c++) sample[c] += pixels[i + c] * pixels[i + 3];
  }
  return sample.map((v) => (weight > 0 ? v / weight : 0));
}

const decode = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const encode = (c) =>
  c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055;

export async function compositeSelection(
  source,
  ground,
  developed,
  selection,
  showMask = false,
  stale = () => false,
) {
  const result = ground.slice();
  const maximum = ground instanceof Uint16Array ? 65535 : 255;
  const strip = Math.max(1, Math.floor(32768 / source.width));
  for (let top = 0; top < source.height; top += strip) {
    if (stale()) return null;
    const rows = Math.min(strip, source.height - top);
    const scene = decodeRGBA(source.read(0, top, source.width, rows));
    for (let i = 0; i < scene.length; i += 4) {
      const weight = selectionWeight(scene.subarray(i, i + 3), selection);
      const offset = top * source.width * 4 + i;
      for (let c = 0; c < 3; c++) {
        const base = decode(ground[offset + c] / maximum);
        const local = showMask ? 1 : decode(developed[offset + c] / maximum);
        result[offset + c] = Math.round(
          maximum *
            encode(
              (showMask ? base * 0.3 : base) * (1 - weight) + local * weight,
            ),
        );
      }
    }
    await yieldToBrowser();
  }
  return result;
}
