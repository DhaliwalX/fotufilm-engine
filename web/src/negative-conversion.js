import {
  takeNegativeWorker,
  returnNegativeWorker,
} from "./negative-worker-pool.js";
import { assetUrl } from "./engine.js";
import { loadFilmProfile } from "./film-profile.js";
import { defaultEdit } from "./editor-state.js";
import { rawSource } from "./raw-source.js";
import { LinearImage } from "./linear-image.js";
import { loadStockIndex } from "./stock-index.js";

// Previews read one resampled copy of the scan. Resampling a large photo decodes
// all of it, so each analysis and preview conversion would otherwise pay for that.
const PREVIEW_EDGE = 1200;
const previewScans = new WeakMap();
function previewScan(image) {
  let scan = previewScans.get(image);
  if (!scan) {
    const source = rawSource(image, defaultEdit(), PREVIEW_EDGE);
    scan = new LinearImage({
      pixels: source.read(0, 0, source.width, source.height),
      width: source.width,
      height: source.height,
    });
    previewScans.set(image, scan);
  }
  return scan;
}

// The native analyses read one 512-pixel copy of the scan, packed as planar
// little-endian float32: that keeps a full 512² preview under the WASI request
// limit without rounding transmission values.
const analysisPreviews = new WeakMap();
function analysisPreview(image) {
  let preview = analysisPreviews.get(image);
  if (preview) return preview;
  const source = rawSource(previewScan(image), defaultEdit(), 512);
  if (source.width < 2 || source.height < 2)
    throw new Error("The negative is too small to analyse.");
  const pixels = source.read(0, 0, source.width, source.height);
  const count = source.width * source.height;
  const packed = new Uint8Array(count * 3 * 4);
  const view = new DataView(packed.buffer);
  for (let c = 0; c < 3; c++)
    for (let i = 0; i < count; i++)
      view.setFloat32((c * count + i) * 4, pixels[4 * i + c], true);
  const chunks = [];
  for (let i = 0; i < packed.length; i += 16384)
    chunks.push(String.fromCharCode(...packed.subarray(i, i + 16384)));
  preview = {
    width: source.width,
    height: source.height,
    samples: btoa(chunks.join("")),
  };
  analysisPreviews.set(image, preview);
  return preview;
}

export async function analyseNegative(image, monochrome = false, onProgress) {
  const bytes = await loadFilmProfile(
    {
      kind: "negative-auto",
      ...analysisPreview(image),
      monochrome,
      rec2020: true,
    },
    onProgress,
  );
  return JSON.parse(new TextDecoder().decode(bytes));
}

// The installed negatives and their predicted clear bases, read once.
let negativeFilms = null;
function loadNegativeFilms() {
  negativeFilms ??= loadStockIndex().then((stocks) =>
    stocks
      .filter((stock) => stock.profile.filmBase)
      .map(({ id, name, profile }) => ({ id, name, base: profile.filmBase })),
  );
  return negativeFilms.catch((error) => {
    negativeFilms = null;
    throw error;
  });
}

// The installed films whose clear base the scan's looks like, most likely first.
export async function suggestNegativeFilms(image) {
  const films = await loadNegativeFilms();
  if (!films.length) return [];
  const bytes = await loadFilmProfile({
    kind: "negative-film",
    ...analysisPreview(image),
    films,
  });
  const names = new Map(films.map((film) => [film.id, film.name]));
  return JSON.parse(new TextDecoder().decode(bytes)).suggestions.map(
    (suggestion) => ({
      films: suggestion.films.map((id) => ({ id, name: names.get(id) })),
      likelihood: suggestion.likelihood,
    }),
  );
}

// The inverse sigmoid's slope at mid-grey, scaled by 2^contrast from the plan's.
const CONTRAST_PARAMETER = 6;
function planParameters(plan, contrast) {
  const parameters = [...plan.parameters];
  parameters[CONTRAST_PARAMETER] *= 2 ** contrast;
  return parameters;
}

export function convertNegative(
  image,
  plan,
  {
    signal,
    maxEdge = Infinity,
    contrast = 0,
    preferGpu = true,
    onProgress = () => {},
  } = {},
) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted)
      return reject(new DOMException("Conversion cancelled.", "AbortError"));
    if (
      !Array.isArray(plan?.parameters) ||
      plan.parameters.length !== 8 ||
      !plan.parameters.every(Number.isFinite)
    )
      return reject(new Error("Invalid negative conversion settings."));
    const input = maxEdge <= PREVIEW_EDGE ? previewScan(image) : image;
    const source = rawSource(input, defaultEdit(), maxEdge);
    if (source.width * source.height > 120000000)
      return reject(
        new Error("Images above 120 megapixels are not supported."),
      );
    const worker = takeNegativeWorker();
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      if (error) {
        worker.terminate();
        reject(error);
      } else {
        returnNegativeWorker(worker);
        resolve(value);
      }
    };
    const abort = () =>
      finish(new DOMException("Conversion cancelled.", "AbortError"));
    const timer = setTimeout(
      () => finish(new Error("Negative conversion timed out.")),
      180000,
    );
    signal?.addEventListener("abort", abort, { once: true });
    worker.onerror = () =>
      finish(new Error("The negative converter could not run."));
    worker.onmessage = async ({ data }) => {
      if (data.kind === "read") {
        try {
          const pixels = await source.read(
            data.x,
            data.y,
            data.width,
            data.height,
          );
          if (!settled)
            worker.postMessage({ kind: "pixels", id: data.id, pixels }, [
              pixels.buffer,
            ]);
        } catch (error) {
          if (!settled)
            worker.postMessage({
              kind: "pixels",
              id: data.id,
              error: error.message,
            });
        }
      } else if (data.kind === "progress") onProgress(data);
      else if (data.kind === "error") finish(new Error(data.error));
      else if (data.kind === "done") {
        const positive = new LinearImage({
          pixels: data.pixels,
          width: source.width,
          height: source.height,
        });
        positive.deep = { format: "Positive", bitDepth: 32 };
        finish(null, { image: positive, backend: data.backend });
      }
    };
    worker.postMessage({
      kind: "convert",
      width: source.width,
      height: source.height,
      parameters: planParameters(plan, contrast),
      preferGpu,
      base: assetUrl("negative/"),
    });
  });
}
