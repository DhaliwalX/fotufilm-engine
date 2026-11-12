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

// A scan's stray light: what the lens and the room add to every sample alike, which a reading
// takes off before a density is read. Mirrors Sources/FotufilmCore/NegativeScanFlare.swift and
// WebNativeEdit.Negative.strayLight (Sources/FotufilmEditModel/WebNativeEdit+NegativeReading.swift).

// The shares of a frame's average light an edit's flare can be, and how much of a channel's
// clear film can be stray light.
export const FLARE_SHARES = [0, 0.02];
const FLARE_LIMIT = 0.5;

const finite = (pixels, i) => [0, 1, 2].every((c) => Number.isFinite(pixels[i + c]));

// The framed picture's average light, linear scan RGB: the mean over the central 80% of the
// samples that are numbers, none counted under zero. Null for a frame too small to read.
export function frameLight(pixels, width, height) {
  if (width < 2 || height < 2) return null;
  const mx = Math.floor(width / 10),
    my = Math.floor(height / 10);
  const sum = [0, 0, 0];
  let count = 0;
  for (let y = my; y < height - my; y++)
    for (let x = mx; x < width - mx; x++) {
      const i = (y * width + x) * 4;
      if (!finite(pixels, i)) continue;
      for (let c = 0; c < 3; c++) sum[c] += Math.max(pixels[i + c], 0);
      count++;
    }
  return count >= 16 ? sum.map((v) => v / count) : null;
}

// The stray light of a whole scan that shows its holder, read from the holder. The holder is
// taken to be in view only where the darkest twentieth of the scan lies around its edge, is even
// to within a stop, and is darker than the densest film in the scan's middle by a stop or more in
// every channel. It is then that twentieth's lower quartile, no more than the largest share of
// the middle's average light an edit's flare can be. Null where no holder shows, or it shows no
// light.
export function strayLight(border, pixels, width, height) {
  return holder(border, pixels, width, height)?.stray ?? null;
}

// The light a whole scan's holder shows (`light`), the stray light read from it (`stray`,
// above) and where the holder ends (`limit`, a density over the clear film): all from one look
// at the scan. Null where no holder shows. Mirrors ApproximateNegativeScan.holder.
export function holder(border, pixels, width, height) {
  if (width < 16 || height < 16 || !border.every((v) => Number.isFinite(v) && v > 0)) return null;
  const lit = [];
  for (let index = 0; index < width * height; index++) {
    const i = index * 4;
    if (!finite(pixels, i)) continue;
    let light = 0;
    for (let c = 0; c < 3; c++) light += Math.fround(Math.max(pixels[i + c], 0) / border[c]);
    lit.push({ index, light: Math.fround(light) });
  }
  if (lit.length < 320) return null;
  const mx = Math.floor(width / 5),
    my = Math.floor(height / 5);
  const central = (index) => {
    const x = index % width,
      y = Math.floor(index / width);
    return x >= mx && x < width - mx && y >= my && y < height - my;
  };
  const count = Math.max(16, Math.floor(lit.length / 20));
  lit.sort((a, b) => a.light - b.light || a.index - b.index);
  const dark = lit.slice(0, count);
  const outside = dark.reduce((n, { index }) => n + (central(index) ? 0 : 1), 0);
  if (outside * 5 < count * 4) return null;
  const low = dark[Math.floor((count - 1) / 10)].light,
    high = dark[Math.floor(((count - 1) * 9) / 10)].light;
  if (!(low > 0) || high > 2 * low) return null;
  const middle = [[], [], []];
  for (let index = 0; index < width * height; index++) {
    if (!central(index) || !finite(pixels, index * 4)) continue;
    for (let c = 0; c < 3; c++) middle[c].push(Math.max(pixels[index * 4 + c], 0));
  }
  if (middle[0].length < 16) return null;
  const light = [0, 0, 0],
    stray = [0, 0, 0],
    densest = [0, 0, 0];
  for (let c = 0; c < 3; c++) {
    const values = dark.map(({ index }) => Math.max(pixels[index * 4 + c], 0)).sort((a, b) => a - b);
    const shown = values[Math.floor((count - 1) / 4)];
    const film = middle[c].sort((a, b) => a - b);
    densest[c] = film[Math.floor((film.length - 1) / 1000)];
    if (shown * 2 > densest[c]) return null;
    const mean = film.reduce((a, b) => a + b, 0) / film.length;
    light[c] = shown;
    stray[c] = Math.min(shown, FLARE_SHARES[1] * mean);
  }
  if (!(Math.min(...light) > 0) || !(Math.min(...densest) > 0)) return null;
  // Where the holder ends: the fewest pixels between the middle's densest film and the holder,
  // by the mean of a pixel's channels' densities over the clear film.
  const density = (v) => -(Math.log10(v[0] / border[0]) + Math.log10(v[1] / border[1]) + Math.log10(v[2] / border[2])) / 3;
  const from = density(densest),
    to = density(light);
  const bins = Math.trunc((to - from) / HOLDER_BIN);
  if (bins < 2) return { light, stray, limit: (from + to) / 2 };
  const counts = new Array(bins).fill(0);
  for (let i = 0; i < width * height * 4; i += 4) {
    if (!finite(pixels, i) || !positive(pixels, i)) continue;
    const bin = Math.floor((density([pixels[i], pixels[i + 1], pixels[i + 2]]) - from) / HOLDER_BIN);
    if (bin >= 0 && bin < bins) counts[bin]++;
  }
  const smoothed = counts.map(
    (_, i) => (counts[Math.max(i - 1, 0)] + 2 * counts[i] + counts[Math.min(i + 1, bins - 1)]) / 4,
  );
  // The middle of the widest stretch as empty as the emptiest step.
  const empty = Math.min(...smoothed) + width * height * 0.0005;
  let best = [0, 1],
    run = null;
  for (let i = 0; i <= bins; i++) {
    if (i < bins && smoothed[i] <= empty) run = [run ? run[0] : i, i + 1];
    else if (run) {
      if (run[1] - run[0] > best[1] - best[0] || smoothed[best[0]] > empty) best = run;
      run = null;
    }
  }
  return { light, stray, limit: from + ((best[0] + best[1]) / 2) * HOLDER_BIN };
}

const HOLDER_BIN = 0.05;

// A framed picture with the scan's holder left out, for what a reading measures of the frame:
// its densest end, which times the print, would otherwise be the holder's where a scan shows
// much of one. A pixel is the holder's where its density over `border`, the mean of its
// channels', is past `limit` (holder), or it passes no light, or it lies beside one that is;
// it is made no number, which the measures pass over. Mirrors
// ApproximateNegativeScan.withoutHolder.
export function withoutHolder(pixels, width, height, border, limit) {
  const count = width * height;
  const shown = new Uint8Array(count);
  for (let p = 0; p < count; p++) {
    const i = p * 4;
    const kept =
      positive(pixels, i) &&
      -(
        Math.log10(pixels[i] / border[0]) +
        Math.log10(pixels[i + 1] / border[1]) +
        Math.log10(pixels[i + 2] / border[2])
      ) /
        3 <=
        limit;
    shown[p] = kept ? 0 : 1;
  }
  // The holder's edge is blurred into the film beside it, so the holder is grown over those
  // pixels, by a hundredth of the frame's long edge.
  const reach = Math.max(2, Math.floor(Math.max(width, height) / 100));
  const across = new Uint8Array(shown);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      if (shown[y * width + x]) continue;
      const to = Math.min(width - 1, x + reach);
      for (let k = Math.max(0, x - reach); k <= to; k++)
        if (shown[y * width + k]) {
          across[y * width + x] = 1;
          break;
        }
    }
  const film = new Float32Array(pixels);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const to = Math.min(height - 1, y + reach);
      for (let k = Math.max(0, y - reach); k <= to; k++)
        if (across[k * width + x]) {
          for (let c = 0; c < 3; c++) film[(y * width + x) * 4 + c] = NaN;
          break;
        }
    }
  return film;
}

// The stray light a reading takes off the scan: the edit's share of the frame's `light`
// (frameLight), or where the edit leaves it to be measured what the scan's `holder` shows
// (strayLight), none where it shows none. No more than half the clear film's, and none on the
// first reading.
export function readingFlare(negative, border, light, holder) {
  if ((negative?.reading ?? 1) < 2) return [0, 0, 0];
  const share =
    negative.flare == null
      ? null
      : Math.min(Math.max(negative.flare, FLARE_SHARES[0]), FLARE_SHARES[1]);
  const stray = share == null ? (holder ?? [0, 0, 0]) : (light ?? [0, 0, 0]).map((v) => v * share);
  return stray.map((v, c) =>
    Number.isFinite(v) && Number.isFinite(border[c]) && border[c] > 0
      ? Math.min(Math.max(v, 0), FLARE_LIMIT * border[c])
      : 0,
  );
}

// Scan `pixels` with `flare` taken off each channel, for the measures a reading takes net of it.
export function netOfFlare(pixels, flare) {
  if (!flare.some((v) => v > 0)) return pixels;
  const net = new Float32Array(pixels.length);
  for (let i = 0; i < pixels.length; i += 4) {
    for (let c = 0; c < 3; c++) net[i + c] = pixels[i + c] - flare[c];
    net[i + 3] = pixels[i + 3];
  }
  return net;
}

// How red and blue rise per unit of green across the framed picture's tonal steps, in the scan
// channels' densities over `border`: the medians over pairs of pixels a little apart in the
// central 80% whose green differs by a tenth of a density or more. A roll's frames give it how
// steep its records read against each other. Null for a frame with too few steps to tell.
// Mirrors ApproximateNegativeScan.tonalSlopes in Sources/FotufilmCore/NegativeScanContrast.swift.
export function tonalSlopes(border, pixels, width, height) {
  if (width < 2 || height < 2 || !border.every((v) => Number.isFinite(v) && v > 0)) return null;
  const mx = Math.floor(width / 10),
    my = Math.floor(height / 10);
  const w = width - 2 * mx,
    h = height - 2 * my;
  const density = [0, 1, 2].map(() => new Float32Array(w * h).fill(NaN));
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const i = ((y + my) * width + x + mx) * 4;
      if (!positive(pixels, i)) continue;
      for (let c = 0; c < 3; c++) density[c][y * w + x] = -Math.log10(pixels[i + c] / border[c]);
    }
  // Far enough apart to span an edge the preview has softened.
  const apart = Math.max(1, Math.floor(Math.max(width, height) / 170));
  const red = [],
    blue = [];
  const step = (from, to) => {
    const green = density[1][to] - density[1][from];
    if (!(Math.abs(green) >= 0.1)) return;
    const rises = [0, 2].map((c) => (density[c][to] - density[c][from]) / green);
    if (!rises.every(Number.isFinite)) return;
    red.push(rises[0]);
    blue.push(rises[1]);
  };
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      if (x + apart < w) step(y * w + x, y * w + x + apart);
      if (y + apart < h) step(y * w + x, (y + apart) * w + x);
    }
  if (red.length < 256) return null;
  red.sort((a, b) => a - b);
  blue.sort((a, b) => a - b);
  return [red[red.length >> 1], blue[blue.length >> 1]];
}

// The full crosstalk correction of a scan read without a film, by the light it was scanned under:
// what each channel reads from the three channels' densities, rows summing to one, before the
// frame's densest end is kept. NegativeScanCrosstalk.plainWeights in
// Sources/FotufilmCore/NegativeScanCrosstalk.swift, which NegativeScanCrosstalkTests pins.
export const PLAIN_CROSSTALK = {
  white: [
    [1.8741934, -0.8167563, -0.057437092],
    [-0.07067131, 1.0591061, 0.011565179],
    [0.0047098156, -0.04486931, 1.0401592],
  ],
  rgb: [
    [1.014058, -0.014435816, 0.00037779874],
    [-1.604771e-5, 1.0268912, -0.02687511],
    [7.733554e-9, -0.0008941038, 1.0008941],
  ],
};

const dot = (row, v) => row[0] * v[0] + row[1] * v[1] + row[2] * v[2];

// The plain reading's weights: `strength` of the way from each channel alone to the full
// correction for `light`, its rows scaled so the frame's densest end `neutral` reads as it did, or
// to sum to one where there is none or a row would scale by more than two. Mirrors
// NegativeScanCrosstalk.weights(dyes:correction:neutral:).
export function plainCrosstalk(strength = 0, light = "white", neutral = null) {
  const s = Number.isFinite(strength) ? Math.min(Math.max(strength, 0), 1) : 0;
  const identity = [0, 1, 2].map((r) => [0, 1, 2].map((c) => (r === c ? 1 : 0)));
  if (!(s > 0)) return identity;
  const rows = PLAIN_CROSSTALK[light] ?? PLAIN_CROSSTALK.white;
  const scales = (target) => {
    const scale = rows.map((row, r) => target[r] / dot(row, target));
    return scale.every((v) => Number.isFinite(v) && v >= 0.5 && v <= 2) ? scale : null;
  };
  const readable =
    Array.isArray(neutral) && neutral.every((v) => Number.isFinite(v) && v > 0.05) ? neutral : null;
  const scale = (readable && scales(readable)) ?? scales([1, 1, 1]) ?? [1, 1, 1];
  return rows.map((row, r) =>
    row.map((w, c) => identity[r][c] + s * (w * scale[r] - identity[r][c])),
  );
}

// The scan read without a film, as Normal reads a negative (Sources/FotufilmCore/
// PlainNegativeScan.swift): each channel's density above the clear base, weighted across the
// channels against the dyes' crosstalk, balanced on the frame's densest end. The reading's light
// comes from the engine's scan preparation.
export function plainReading(border, raw, crosstalk = 0, scanLight = "white") {
  const weights = plainCrosstalk(crosstalk, scanLight, raw);
  const gains = [1, 1, 1];
  let reference = 1;
  const dense =
    raw && raw.every(Number.isFinite)
      ? weights.map((row) => row[0] * raw[0] + row[1] * raw[1] + row[2] * raw[2])
      : null;
  if (dense && dense[1] > 0.05) {
    reference = dense[1];
    for (const channel of [0, 2])
      if (dense[channel] > 0.05)
        gains[channel] = Math.min(Math.max(dense[1] / dense[channel], 0.5), 2);
  }
  return { border, gains, reference, weights };
}

// The median of the scan over a patch of the framed picture around `point`, normalised to the
// frame, each channel read from the positive, finite samples, which must be nine in ten of them:
// clear film to read the scan against, or something neutral in the picture to balance it on.
export const filmBase = (source, point) => scanPatch(source, point, INVALID_BORDER);
export const pickedNeutral = (source, point) => scanPatch(source, point, INVALID_NEUTRAL);

function scanPatch(source, point, unreadable) {
  const { width, height } = source;
  const radius = Math.max(2, Math.floor(Math.max(width, height) / 80));
  const x = Math.floor(point[0] * width),
    y = Math.floor(point[1] * height);
  const x0 = Math.max(0, x - radius),
    y0 = Math.max(0, y - radius);
  const x1 = Math.min(width, x + radius + 1),
    y1 = Math.min(height, y + radius + 1);
  if (x1 - x0 < 2 || y1 - y0 < 2) throw new Error(unreadable);
  const pixels = decodeRGBA(source.read(x0, y0, x1 - x0, y1 - y0));
  const count = (x1 - x0) * (y1 - y0);
  return [0, 1, 2].map((c) => {
    const values = [];
    for (let i = 0; i < count; i++) {
      const v = pixels[i * 4 + c];
      if (Number.isFinite(v) && v > 0) values.push(v);
    }
    if (!values.length || values.length < Math.floor((count * 9) / 10))
      throw new Error(unreadable);
    return values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
  });
}

export const INVALID_BORDER =
  "Pick clear, unexposed film: the gap between frames or the film's edge, away from the holder, sprocket holes and lettering.";
export const INVALID_NEUTRAL =
  "Pick something grey or white in the picture, where the scan shows the film.";

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

// How many values a plain reading hands the scan preparation (web/engine/negative_wasm.cpp):
// clear film, gains, reference, weights, stray light, the toe's light and the light scales.
const PLAIN_PARAMETERS = 23;

// Reads linear scan RGBA `pixels` of `width`×`height`, in place, as the plain reading's scene
// light with `module` (loadScanPreparation); black where a sample passes no light. The reading is
// plainReading's, or the engine's own for the current reading (WebNegativePlainRequest.Result).
export function readPlain(
  module,
  pixels,
  width,
  height,
  // The first reading has no stray light, toe or balance: a straight line.
  { border, gains, reference, weights, flare = [0, 0, 0], toe = 0, scale = [1, 1, 1] },
) {
  const bytes = pixels.length * 4;
  const data = module._malloc(bytes),
    reading = module._malloc(PLAIN_PARAMETERS * 4);
  if (!data || !reading) {
    module._free(data);
    module._free(reading);
    throw new Error("Not enough memory to read the negative.");
  }
  try {
    module.HEAPF32.set(pixels, data / 4);
    module.HEAPF32.set(
      [...border, ...gains, reference, ...weights.flat(), ...flare, toe, ...scale],
      reading / 4,
    );
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
