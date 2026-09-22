import {
  takeNegativeWorker,
  returnNegativeWorker,
} from "./negative-worker-pool.js";
import { assetUrl } from "./engine.js";
import { loadFilmProfile } from "./film-profile.js";
import { defaultEdit } from "./editor-state.js";
import { rawSource } from "./raw-source.js";
import { LinearImage } from "./linear-image.js";

export async function analyseNegative(image, monochrome = false, onProgress) {
  const source = rawSource(image, defaultEdit(), 512);
  if (source.width < 2 || source.height < 2)
    throw new Error("The negative is too small to analyse.");
  const pixels = source.read(0, 0, source.width, source.height);
  // Packed little-endian float32 keeps a full 512² analysis under the WASI
  // request limit without rounding transmission values or shrinking the preview.
  const count = source.width * source.height;
  const packed = new Uint8Array(count * 3 * 4);
  const view = new DataView(packed.buffer);
  for (let c = 0; c < 3; c++)
    for (let i = 0; i < count; i++)
      view.setFloat32((c * count + i) * 4, pixels[4 * i + c], true);
  const chunks = [];
  for (let i = 0; i < packed.length; i += 16384)
    chunks.push(String.fromCharCode(...packed.subarray(i, i + 16384)));
  const samples = btoa(chunks.join(""));
  const bytes = await loadFilmProfile(
    {
      kind: "negative-auto",
      width: source.width,
      height: source.height,
      samples,
      monochrome,
      rec2020: true,
    },
    onProgress,
  );
  return JSON.parse(new TextDecoder().decode(bytes));
}

export function convertNegative(
  image,
  plan,
  { signal, maxEdge = Infinity, preferGpu = true, onProgress = () => {} } = {},
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
    const source = rawSource(image, defaultEdit(), maxEdge);
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
      parameters: plan.parameters,
      preferGpu,
      base: assetUrl("negative/"),
    });
  });
}
