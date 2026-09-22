import { previewToOKLab } from "./histogram-color.js";
import { INGEST_COLOR } from "./engine-constants.js";
export const HISTOGRAM_EDGE = 256;

// Counts describe the encoded display preview, in its own RGB color space.
export function histogramStatistics({ data, colorSpace = "srgb" }) {
  const bins = Array.from({ length: 3 }, () => new Uint32Array(256));
  const oklab = Array.from({ length: 3 }, () => new Uint32Array(256));
  const luma = new Uint32Array(256);
  const chroma = Array.from({ length: 2 }, () => new Uint32Array(256));
  // Derive coefficients from the engine's primaries, including Display P3.
  const matrix =
    colorSpace === "display-p3"
      ? INGEST_COLOR.linearDisplayP3ToRec2020
      : INGEST_COLOR.linearSRGBToRec2020;
  const weights = [0, 1, 2].map((c) =>
    INGEST_COLOR.luminanceWeights.reduce(
      (sum, w, r) => sum + w * matrix[r * 3 + c],
      0,
    ),
  );
  const total = weights.reduce((a, b) => a + b);
  const kr = weights[0] / total,
    kb = weights[2] / total;
  const bin = (v) => Math.max(0, Math.min(255, Math.round(v)));
  // Treat numerical residue around the neutral axis as exactly zero.
  const opponentBin = (value) =>
    Math.abs(value) < 1e-7 ? 128 : bin((value / 0.8 + 0.5) * 255);
  let count = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (!data[i + 3]) continue;
    for (let c = 0; c < 3; c++) bins[c][data[i + c]]++;
    const r = data[i],
      g = data[i + 1],
      b = data[i + 2];
    const y = g + kr * (r - g) + kb * (b - g);
    luma[bin(y)]++;
    // Full-range colour differences, neutral at bin 128. BT.709 construction
    // generalized to the preview primaries (encoded signals, not linear light):
    // https://www.itu.int/rec/R-REC-BT.709
    chroma[0][bin(127.5 + (b - y) / (2 * (1 - kb)))]++;
    chroma[1][bin(127.5 + (r - y) / (2 * (1 - kr)))]++;
    const [L, a, opponentB] = previewToOKLab(r, g, b, colorSpace);
    oklab[0][bin(L * 255)]++;
    oklab[1][opponentBin(a)]++;
    oklab[2][opponentBin(opponentB)]++;
    count++;
  }
  return { bins, luma, chroma, oklab, count };
}
