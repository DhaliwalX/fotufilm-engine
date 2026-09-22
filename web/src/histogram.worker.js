import { HISTOGRAM_EDGE, histogramStatistics } from "./histogram-model.js";
let generation = 0;
async function sample(blob, colorSpace) {
  const bitmap = await createImageBitmap(blob);
  try {
    const scale = Math.min(
      1,
      HISTOGRAM_EDGE / Math.max(bitmap.width, bitmap.height),
    );
    const width = Math.max(1, Math.round(bitmap.width * scale)),
      height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d", {
      colorSpace,
      willReadFrequently: true,
    });
    if (!context)
      throw new Error("Histogram color space is unavailable.");
    context.drawImage(bitmap, 0, 0, width, height);
    // Safari's worker context may omit getContextAttributes. The readback
    // describes the actual sample space, including any browser conversion.
    const pixels = context.getImageData(0, 0, width, height, { colorSpace });
    return {
      data: pixels.data,
      width,
      height,
      colorSpace: pixels.colorSpace || "srgb",
    };
  } finally {
    bitmap.close();
  }
}
self.onmessage = async ({ data }) => {
  generation = data.generation;
  try {
    const frame = await sample(data.output, data.colorSpace);
    if (generation !== data.generation) return;
    self.postMessage({ generation, analysis: histogramStatistics(frame) });
  } catch (error) {
    self.postMessage({ generation: data.generation, error: error.message });
  }
};
