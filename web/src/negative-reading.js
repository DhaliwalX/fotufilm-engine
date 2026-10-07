import { assetUrl, decodeRGBA } from "./engine.js";
import { relatedAssetUrl } from "./runtime-assets.js";

// What the browser measures of a scanned negative, as the desktop host measures it
// (Sources/FotufilmHost/HostNegativeScan.swift). Scans are linear Rec. 2020 RGBA. The engine's
// kernels read the pixels: the print profile reads a scan as the film
// (`negative` in Sources/FotufilmEditModel/WebProfileRequest.swift), and the scan preparation
// module reads one without a film.

// A scan drawn down to the readings' 512 pixels by area, as the desktop host draws it
// (Sources/FotufilmHost/AreaResample.swift): every output pixel is the exact mean of the scan it
// covers. The readings take a scan's extremes, which a sharper resampler would overshoot and
// point sampling would leave grainy.
export function areaPreview(pixels, width, height, maxEdge = 512) {
  const longest = Math.max(width, height);
  if (longest <= maxEdge) return { pixels, width, height };
  const scale = maxEdge / longest;
  const w = Math.max(1, Math.round(width * scale)),
    h = Math.max(1, Math.round(height * scale));
  const taps = (source, target) =>
    Array.from({ length: target }, (_, index) => {
      const step = source / target,
        start = index * step,
        end = start + step;
      const first = Math.floor(start),
        last = Math.min(source - 1, Math.floor(end - 1e-9));
      const weights = [];
      for (let i = first; i <= last; i++)
        weights.push((Math.min(end, i + 1) - Math.max(start, i)) / step);
      return { first, weights };
    });
  const columns = taps(width, w),
    rows = taps(height, h);
  const horizontal = new Float32Array(w * height * 4);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < w; x++) {
      const { first, weights } = columns[x];
      const o = (y * w + x) * 4;
      for (let k = 0; k < weights.length; k++) {
        const i = (y * width + first + k) * 4;
        for (let c = 0; c < 4; c++) horizontal[o + c] += pixels[i + c] * weights[k];
      }
    }
  const reduced = new Float32Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const { first, weights } = rows[y];
    for (let k = 0; k < weights.length; k++)
      for (let x = 0; x < w; x++) {
        const i = ((first + k) * w + x) * 4,
          o = (y * w + x) * 4;
        for (let c = 0; c < 4; c++) reduced[o + c] += horizontal[i + c] * weights[k];
      }
  }
  return { pixels: reduced, width: w, height: h };
}

const positive = (pixels, i) =>
  [0, 1, 2].every((c) => Number.isFinite(pixels[i + c]) && pixels[i + c] > 0);

// A stand-in for the film border until one is sampled: the median of the percent of the scan
// that passes the most light across all three channels. Null when no pixel passes light.
export function estimatedBorder(pixels) {
  const film = [];
  for (let i = 0; i < pixels.length; i += 4)
    if (positive(pixels, i))
      film.push({
        i,
        transmission: Math.log10(pixels[i]) + Math.log10(pixels[i + 1]) + Math.log10(pixels[i + 2]),
      });
  if (!film.length) return null;
  film.sort((a, b) => b.transmission - a.transmission);
  const brightest = film.slice(0, Math.max(1, Math.floor(film.length / 100)));
  return [0, 1, 2].map((c) => {
    const values = brightest.map(({ i }) => pixels[i + c]).sort((a, b) => a - b);
    return values[Math.floor(values.length / 2)];
  });
}

// The framed picture's densest end, its highlights: each channel's scanner density over `border`
// at the 99.5th percentile of the central 80%. Null for a frame too small to read.
export function denseEnd(border, pixels, width, height) {
  if (width < 2 || height < 2) return null;
  const channels = [[], [], []];
  const mx = Math.floor(width / 10),
    my = Math.floor(height / 10);
  for (let y = my; y < height - my; y++)
    for (let x = mx; x < width - mx; x++) {
      const i = (y * width + x) * 4;
      if (!positive(pixels, i)) continue;
      for (let c = 0; c < 3; c++) channels[c].push(-Math.log10(pixels[i + c] / border[c]));
    }
  if (channels[0].length < 16) return null;
  return channels.map((values) => {
    values.sort((a, b) => a - b);
    return values[Math.trunc((values.length - 1) * 0.995)];
  });
}

// The scan read without a film, as Normal reads a negative (Sources/FotufilmCore/
// PlainNegativeScan.swift): each channel's density above the clear base balanced on the frame's
// densest end. The reading's light comes from the engine's scan preparation.
export function plainReading(border, dense) {
  const gains = [1, 1, 1];
  let reference = 1;
  if (dense && dense.every(Number.isFinite) && dense[1] > 0.05) {
    reference = dense[1];
    for (const channel of [0, 2])
      if (dense[channel] > 0.05)
        gains[channel] = Math.min(Math.max(dense[1] / dense[channel], 0.5), 2);
  }
  return { border, gains, reference };
}

// The median clear film over a patch of framed scan around `point`, normalised to the frame,
// each channel read from the positive, finite samples, which must be nine in ten of them.
export function filmBase(source, point) {
  const { width, height } = source;
  const radius = Math.max(2, Math.floor(Math.max(width, height) / 80));
  const x = Math.floor(point[0] * width),
    y = Math.floor(point[1] * height);
  const x0 = Math.max(0, x - radius),
    y0 = Math.max(0, y - radius);
  const x1 = Math.min(width, x + radius + 1),
    y1 = Math.min(height, y + radius + 1);
  if (x1 - x0 < 2 || y1 - y0 < 2) throw new Error(INVALID_BORDER);
  const pixels = decodeRGBA(source.read(x0, y0, x1 - x0, y1 - y0));
  const count = (x1 - x0) * (y1 - y0);
  return [0, 1, 2].map((c) => {
    const values = [];
    for (let i = 0; i < count; i++) {
      const v = pixels[i * 4 + c];
      if (Number.isFinite(v) && v > 0) values.push(v);
    }
    if (!values.length || values.length < Math.floor((count * 9) / 10))
      throw new Error(INVALID_BORDER);
    return values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
  });
}

export const INVALID_BORDER =
  "Pick clear, unexposed film: the gap between frames or the film's edge, away from the holder, sprocket holes and lettering.";

// The engine's scan preparation (Sources/FotufilmHalide/Pipeline/NegativeScan.h), built by
// tools/build-negative-wasm.sh and loaded once.
let preparation = null;
export function loadScanPreparation(url = assetUrl("negative/prepare.mjs")) {
  preparation ??= import(/* @vite-ignore */ url)
    .then(({ default: create }) => create({ locateFile: (name) => relatedAssetUrl(name, url) }))
    .catch((error) => {
      preparation = null;
      throw error;
    });
  return preparation;
}

// Reads linear scan RGBA `pixels` of `width`×`height`, in place, as the plain reading's scene
// light with `module` (loadScanPreparation); black where a sample passes no light.
export function readPlain(module, pixels, width, height, { border, gains, reference }) {
  const bytes = pixels.length * 4;
  const data = module._malloc(bytes),
    reading = module._malloc(7 * 4);
  if (!data || !reading) {
    module._free(data);
    module._free(reading);
    throw new Error("Not enough memory to read the negative.");
  }
  try {
    module.HEAPF32.set(pixels, data / 4);
    module.HEAPF32.set([...border, ...gains, reference], reading / 4);
    const code = module._scan_prepare_plain(data, data, width, height, reading);
    if (code) throw new Error(`The negative could not be read (${code}).`);
    pixels.set(module.HEAPF32.subarray(data / 4, data / 4 + pixels.length));
    return pixels;
  } finally {
    module._free(data);
    module._free(reading);
  }
}

// The framed scan as the plain reading's scene-linear light.
export function positiveSource(source, reading, module) {
  return {
    width: source.width,
    height: source.height,
    read(x, y, w, h) {
      return readPlain(module, decodeRGBA(source.read(x, y, w, h)), w, h, reading);
    },
  };
}
