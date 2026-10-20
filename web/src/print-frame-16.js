import { framePalette, renderPrintFrame, stripMasks } from "./print-frame-renderer.js";
import { yieldToBrowser } from "./yield.js";

// Reuse the exact native placement and material drawing. The photo aperture stays
// transparent in Canvas; composite its rim over original 16-bit samples afterwards.
export async function renderPrintFrame16(
  pixels,
  width,
  height,
  plan,
  stale = () => false,
  colorSpace = "srgb",
  { developed = false } = {},
) {
  if (!plan || plan.configuration.frame === "none")
    return { pixels, width, height, colorSpace };
  if (developed) return developedStrip16(pixels, width, height, plan, stale, colorSpace);
  const layer = await renderPrintFrame(null, plan, stale, {
    omitPhoto: true,
    colorSpace,
    rawColors: true,
  });
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
  return {
    pixels: output,
    width: layer.width,
    height: layer.height,
    colorSpace,
  };
}

// A Film Border's developed strip, already the frame's size: its letters and holes blended into
// the strip's own 16-bit samples as the 8-bit compositor blends them (multiply for a negative's
// denser letters, screen for lighter ones), and an inverted scan's rebate lifted off black.
async function developedStrip16(pixels, width, height, plan, stale, colorSpace) {
  const p = plan.placement;
  if (p.size.width !== width || p.size.height !== height)
    throw new Error("Print frame dimensions do not match the developed film.");
  const palette = framePalette(plan, colorSpace),
    c = plan.configuration;
  const { letters, bars, holes } = stripMasks(plan);
  const transmission = palette.edgeTransmission,
    ink = transmission || palette.edge,
    barTransmission = palette.barcodeTransmission,
    barInk = barTransmission || palette.barcode,
    cutout = palette.cutout,
    lift = c.frame === "filmPositive" ? palette.base : null;
  const r = p.image,
    top = height - r.y - r.height;
  const output = new Uint16Array(pixels.length);
  for (let y = 0; y < height; y++) {
    if (y % 64 === 0) {
      await yieldToBrowser();
      if (stale()) return null;
    }
    const inPhotoRow = y >= top && y < top + r.height;
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const rebate = !(inPhotoRow && x >= r.x && x < r.x + r.width);
      const letter = letters[i + 3] / 255,
        bar = bars[i + 3] / 255,
        hole = holes[i + 3] / 255;
      for (let ch = 0; ch < 3; ch++) {
        let v = pixels[i + ch] / 65535;
        if (lift && rebate) v = 1 - (1 - v) * (1 - lift[ch]);
        if (letter > 0) {
          const marked = transmission ? v * ink[ch] : 1 - (1 - v) * (1 - ink[ch]);
          v += (marked - v) * letter;
        }
        if (bar > 0) {
          const marked = barTransmission ? v * barInk[ch] : 1 - (1 - v) * (1 - barInk[ch]);
          v += (marked - v) * bar;
        }
        if (hole > 0) v += (cutout[ch] - v) * hole;
        output[i + ch] = Math.round(Math.min(1, Math.max(0, v)) * 65535);
      }
      output[i + 3] = 65535;
    }
  }
  return { pixels: output, width, height, colorSpace };
}
