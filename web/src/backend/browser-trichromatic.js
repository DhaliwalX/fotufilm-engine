import { isRawFile } from "../media-types.js";
import { loadScanPreparation } from "../negative-reading.js";
import { decodeRaw } from "../raw-import.js";
import { decodeTIFF } from "../tiff-import.js";

// Trichromatic scans in the browser (backend/README.md, `mergeTrichromatic`): exposures of
// negatives under red, green and blue light, merged frame by frame into scans as the desktop
// host's TrichromaticRoll merges them, with the engine's measuring and kernels
// (FotufilmTrichromatic.h, built into negative/prepare.mjs). Each scan is offered as a download
// and opened. Exposures are camera RAW files or TIFFs, decoded twice: small to measure, whole to
// merge, so a roll never holds more than one frame's layers.

const BLANK = 3;

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

// Copies `samples` into the module's memory for `body`, then frees them.
function onHeap(module, samples, body) {
  const at = module._malloc(samples.byteLength);
  if (!at) throw new Error("Not enough memory to merge these exposures.");
  try {
    module.HEAPU8.set(new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength), at);
    return body(at);
  } finally {
    module._free(at);
  }
}

function measure(module, exposure) {
  const measured = module._malloc(16 + 4);
  try {
    const status = onHeap(module, exposure.samples, (at) =>
      (exposure.rgb16 ? module._trichromatic_measure_rgb16 : module._fotufilm_trichromatic_measure)(
        at,
        exposure.width,
        exposure.height,
        measured,
        measured + 16,
      ),
    );
    if (status) throw new Error("The exposure could not be read.");
    return {
      colour: Array.from(module.HEAPF32.subarray(measured / 4, measured / 4 + 3)),
      light: module.HEAP32[(measured + 16) / 4],
    };
  } finally {
    module._free(measured);
  }
}

// Index triples (red, green, blue) into `lights`, or throws where the order breaks.
function frames(module, lights, files) {
  const count = lights.length;
  const input = module._malloc(4 * Math.max(1, count)),
    output = module._malloc(4 * Math.max(3, count));
  try {
    module.HEAP32.set(lights, input / 4);
    const made = module._fotufilm_trichromatic_group(input, count, output);
    if (made < 0) {
      const tally = (light) => lights.filter((l) => l === light).length;
      throw new Error(
        `The exposures do not group into frames from ${files[-1 - made].name} on (red ${tally(0)}, ` +
          `green ${tally(1)}, blue ${tally(2)}). Choose each frame's red, green and blue ` +
          "exposures, or whole passes of equal length.",
      );
    }
    return Array.from({ length: made }, (_, f) =>
      Array.from(module.HEAP32.subarray(output / 4 + 3 * f, output / 4 + 3 * f + 3)),
    );
  } finally {
    module._free(input);
    module._free(output);
  }
}

// One frame's scan, as a TIFF File named after its red exposure.
async function mergeFrame(module, sources, colours, { signal, step }) {
  const layers = [];
  const affines = module._malloc(2 * 24 + 12);
  let size = null;
  try {
    for (const [light, file] of sources.entries()) {
      step(light, `Reading ${file.name}`);
      const exposure = await decodeExposure(file, { signal });
      if (size && (size.width !== exposure.width || size.height !== exposure.height))
        throw new Error("The exposures are not the same size.");
      size = { width: exposure.width, height: exposure.height };
      const layer = module._malloc(4 * size.width * size.height);
      if (!layer) throw new Error("Not enough memory to merge these exposures.");
      layers.push(layer);
      const colour = module._malloc(12);
      module.HEAPF32.set(colours[light], colour / 4);
      const status = onHeap(module, exposure.samples, (at) =>
        (exposure.rgb16 ? module._trichromatic_layer_rgb16 : module._fotufilm_trichromatic_layer)(
          at,
          size.width,
          size.height,
          colour,
          layer,
        ),
      );
      module._free(colour);
      if (status) throw new Error("The exposures could not be merged.");
    }
    step(3, `Merging ${sources[0].name}`);
    const report = affines + 48;
    for (const light of [1, 2]) {
      const status = module._fotufilm_trichromatic_register(
        layers[0],
        layers[light],
        size.width,
        size.height,
        affines + 24 * (light - 1),
        report,
      );
      if (status === -4)
        throw new Error(
          "The exposures share too little detail to line up: pick three exposures of the same frame.",
        );
      if (status) throw new Error("The exposures could not be merged.");
    }
    const bytes = Number(module._fotufilm_trichromatic_file_size(size.width, size.height));
    const file = module._malloc(bytes);
    if (!file) throw new Error("Not enough memory to merge these exposures.");
    try {
      const [red, green, blue] = layers;
      if (
        module._fotufilm_trichromatic_merge(red, green, blue, size.width, size.height, affines,
          affines + 24, file, BigInt(bytes))
      )
        throw new Error("The exposures could not be merged.");
      const name = `${sources[0].name.replace(/\.[^.]*$/, "")}-rgb.tif`;
      return new File([module.HEAPU8.slice(file, file + bytes)], name, { type: "image/tiff" });
    } finally {
      module._free(file);
    }
  } finally {
    layers.forEach((layer) => module._free(layer));
    module._free(affines);
  }
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
  const module = await loadScanPreparation();
  if (typeof module._fotufilm_trichromatic_merge !== "function")
    throw new Error("The scan module is out of date. Rebuild it and reload the editor.");
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const ordered = [...(files ?? [])].sort((a, b) => collator.compare(a.name, b.name));
  const cancelled = () => {
    if (signal?.aborted) throw new DOMException("The merge was cancelled.", "AbortError");
  };
  const measured = [];
  for (const [index, file] of ordered.entries()) {
    cancelled();
    onProgress({ progress: (0.2 * index) / ordered.length, status: `Measuring ${file.name}` });
    measured.push(measure(module, await decodeExposure(file, { signal })));
  }
  const lights = measured.map(({ light }) => light);
  const grouped = frames(module, lights, ordered);
  const result = {
    scans: [],
    failures: [],
    blanks: ordered.filter((_, i) => lights[i] === BLANK).map(({ name }) => name),
    others: ordered.filter((_, i) => lights[i] < 0).map(({ name }) => name),
  };
  for (const [number, frame] of grouped.entries()) {
    const sources = frame.map((i) => ordered[i]);
    const step = (light, status) => {
      cancelled();
      onProgress({ progress: 0.2 + (0.8 * (number + light / 4)) / grouped.length, status });
    };
    try {
      const scan = await mergeFrame(module, sources, frame.map((i) => measured[i].colour), {
        signal,
        step,
      });
      download(scan);
      result.scans.push({ file: scan, name: scan.name, sources: sources.map(({ name }) => name) });
    } catch (error) {
      if (error.name === "AbortError") throw error;
      result.failures.push({ sources: sources.map(({ name }) => name), reason: error.message });
    }
  }
  onProgress({ progress: 1, status: "Merged" });
  return result;
}

