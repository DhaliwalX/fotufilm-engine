import { renderPrintFrame } from "./print-frame-renderer.js";
import { yieldToBrowser } from "./yield.js";

// Reuse the exact native placement and material drawing. The photo aperture stays
// transparent in Canvas; composite its rim over original 16-bit samples afterwards.
export async function renderPrintFrame16(
  pixels,
  width,
  height,
  plan,
  stale = () => false,
) {
  if (!plan || plan.configuration.frame === "none")
    return { pixels, width, height };
  const layer = await renderPrintFrame(null, plan, stale, true);
  if (!layer || stale()) return null;
  const context = layer.getContext("2d");
  const output = new Uint16Array(layer.width * layer.height * 4);
  const r = plan.placement.image,
    top = layer.height - r.y - r.height;
  if (r.width !== width || r.height !== height)
    throw new Error("Print frame dimensions do not match the photograph.");
  const rows = Math.max(1, Math.floor(32768 / layer.width));
  for (let y = 0; y < layer.height; y += rows) {
    if (stale()) return null;
    const count = Math.min(rows, layer.height - y);
    const border = context.getImageData(0, y, layer.width, count).data;
    for (let line = 0; line < count; line++) {
      const photoY = y + line - top;
      for (let x = 0; x < layer.width; x++) {
        const b = (line * layer.width + x) * 4,
          out = ((y + line) * layer.width + x) * 4;
        const photoX = x - r.x;
        if (photoX >= 0 && photoX < width && photoY >= 0 && photoY < height) {
          const source = (photoY * width + photoX) * 4;
          const alpha = border[b + 3] / 255;
          for (let c = 0; c < 3; c++)
            output[out + c] = Math.round(
              pixels[source + c] * (1 - alpha) + border[b + c] * 257 * alpha,
            );
          output[out + 3] = 65535;
        } else
          for (let c = 0; c < 4; c++) output[out + c] = border[b + c] * 257;
      }
    }
    await yieldToBrowser();
  }
  return { pixels: output, width: layer.width, height: layer.height };
}
