import { isRawFile } from "../media-types.js";
import { assetUrl } from "../engine.js";
import { decodeRaw } from "../raw-import.js";
import { decodeTIFF } from "../tiff-import.js";

// Trichromatic scans in the browser (backend/README.md, `mergeTrichromatic`): exposures of
// negatives under red, green and blue light, merged frame by frame into scans as the desktop
// host's TrichromaticRoll merges them, with the engine's measuring and kernels
// (FotufilmTrichromatic.h, built into negative/prepare.mjs), all in workers so the editor stays
// responsive. Each scan is offered as a download and opened. Exposures are camera RAW files or
// TIFFs, each decoded once, a few at a time: measured, then its layer kept as a Blob (which the
// browser may hold on disk) until the roll is grouped, since a roll scanned a pass at a time
// completes no frame before its last pass.

const BLANK = 3;

// Reading takes most of the time: registering and merging a frame takes about as long as reading
// one of its exposures.
const READING = 3 / 4;

// An exposure's pixels: the RAW decoder's 16-bit RGB at half size, or a TIFF's float RGBA.
async function decodeExposure(file, options) {
  if (isRawFile(file)) {
    const { raw, naturalWidth: width, naturalHeight: height } = await decodeRaw(file, {
      ...options,
      exposure: true,
    });
    if (raw.colors !== 3) throw new Error(`${file.name} is not a colour RAW file.`);
    return { samples: raw.data, width, height, rgb16: true };
  }
  if (!/\.tiff?$/i.test(file.name))
    throw new Error(`${file.name}: choose camera RAW files or TIFFs.`);
  const { pixels, width, height } = await decodeTIFF(file, { ...options, linearSamples: true });
  return { samples: pixels, width, height, rgb16: false };
}

// Workers that measure, register and merge (trichromatic-worker.js), each with its own scan
// module; a worker takes one task at a time.
function createPool(size) {
  const url = assetUrl("negative/prepare.mjs");
  const workers = Array.from({ length: size }, () => {
    const worker = new Worker(new URL("./trichromatic-worker.js", import.meta.url), {
      type: "module",
    });
    const pending = new Map();
    let next = 0;
    worker.onmessage = ({ data: { id, result, error } }) => {
      const { resolve, reject } = pending.get(id);
      pending.delete(id);
      if (error) reject(new Error(error));
      else resolve(result);
    };
    worker.onerror = (event) => {
      event.preventDefault();
      const failure = new Error("The scan module could not run. Reload the editor and try again.");
      pending.forEach(({ reject }) => reject(failure));
      pending.clear();
    };
    let queue = Promise.resolve();
    const call = (task, input, transfer = []) => {
      const done = queue.then(
        () =>
          new Promise((resolve, reject) => {
            const id = next++;
            pending.set(id, { resolve, reject });
            worker.postMessage({ id, task, url, ...input }, transfer);
          }),
      );
      queue = done.catch(() => {});
      return done;
    };
    return { call, terminate: () => worker.terminate() };
  });
  return {
    workers,
    terminate: () => workers.forEach((worker) => worker.terminate()),
  };
}

// Offers a merged scan as a download, as Export does.
function download(file) {
  const url = URL.createObjectURL(file);
  const link = Object.assign(document.createElement("a"), { href: url, download: file.name });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

export async function mergeTrichromatic(files, { signal, onProgress = () => {} } = {}) {
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const ordered = [...(files ?? [])].sort((a, b) => collator.compare(a.name, b.name));
  const cancelled = () => {
    if (signal?.aborted) throw new DOMException("The merge was cancelled.", "AbortError");
  };
  // Green and blue line up with red side by side, each in a worker of its own.
  const pool = createPool(2);
  const [first, second] = pool.workers;
  try {
    // A few exposures at a time: each decoder is a worker of its own.
    const readers = Math.max(1, Math.min(3, Math.floor((navigator.hardwareConcurrency || 2) / 2)));
    const lights = new Array(ordered.length);
    const layers = new Array(ordered.length);
    let next = 0,
      read = 0,
      failed = false;
    const reader = async () => {
      while (next < ordered.length && !failed) {
        const index = next++;
        const file = ordered[index];
        cancelled();
        onProgress({ progress: (READING * read) / ordered.length, status: `Reading ${file.name}` });
        try {
          const exposure = await decodeExposure(file, { signal });
          cancelled();
          const { samples } = exposure;
          const { light, layer } = await pool.workers[index % 2].call("read", exposure, [
            samples.buffer,
          ]);
          lights[index] = light;
          if (layer) layers[index] = { blob: layer, width: exposure.width, height: exposure.height };
          read += 1;
        } catch (error) {
          failed = true;
          throw error;
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(readers, ordered.length) }, reader));
    // A frame exposed twice under one light, the second time straight away or after its other
    // lights: the later exposure is kept.
    const grouped = [...lights];
    const repeats = [];
    const last = new Map();
    const pictures = layers.flatMap((layer, index) => (layer ? [index] : []));
    for (const [n, later] of pictures.entries()) {
      const earlier = last.get(lights[later]);
      last.set(lights[later], later);
      if (earlier == null) continue;
      const [a, b] = [layers[earlier], layers[later]];
      if (a.width !== b.width || a.height !== b.height) continue;
      cancelled();
      const repeated = await (n % 2 ? second : first).call("repeats", {
        earlier: a.blob,
        later: b.blob,
        width: a.width,
        height: a.height,
      });
      if (!repeated) continue;
      grouped[earlier] = -1;
      repeats.push(ordered[earlier].name);
    }
    const { frames, broken } = await first.call("group", { lights: grouped });
    if (frames == null) {
      const tally = (light) => grouped.filter((l) => l === light).length;
      throw new Error(
        `The exposures do not group into frames from ${ordered[broken].name} on (red ${tally(0)}, ` +
          `green ${tally(1)}, blue ${tally(2)}). Choose each frame's red, green and blue ` +
          "exposures, or whole passes of equal length.",
      );
    }
    const result = {
      scans: [],
      failures: [],
      blanks: ordered.filter((_, i) => lights[i] === BLANK).map(({ name }) => name),
      others: ordered.filter((_, i) => lights[i] < 0).map(({ name }) => name),
      repeats,
      loose: [],
    };
    for (const [number, frame] of frames.entries()) {
      const sources = frame.map((i) => ordered[i]);
      cancelled();
      onProgress({
        progress: READING + ((1 - READING) * number) / frames.length,
        status: `Merging ${sources[0].name}`,
      });
      try {
        const stored = frame.map((i) => layers[i]);
        const { width, height } = stored[0];
        if (stored.some((layer) => layer.width !== width || layer.height !== height))
          throw new Error("The exposures are not the same size.");
        const [red, green, blue] = stored.map(({ blob }) => blob);
        const placed = await Promise.all([
          first.call("register", { reference: red, moving: green, width, height }),
          second.call("register", { reference: red, moving: blue, width, height }),
        ]);
        const bytes = await first.call("merge", {
          stored: [red, green, blue],
          width,
          height,
          green: placed[0].affine,
          blue: placed[1].affine,
        });
        frame.forEach((i) => (layers[i] = null));
        const name = `${sources[0].name.replace(/\.[^.]*$/, "")}-rgb.tif`;
        const scan = new File([bytes], name, { type: "image/tiff" });
        download(scan);
        result.scans.push({ file: scan, name, sources: sources.map(({ name }) => name) });
        if (placed.some(({ loose }) => loose)) result.loose.push(name);
      } catch (error) {
        if (error.name === "AbortError") throw error;
        result.failures.push({ sources: sources.map(({ name }) => name), reason: error.message });
      }
    }
    onProgress({ progress: 1, status: "Merged" });
    return result;
  } finally {
    pool.terminate();
  }
}
