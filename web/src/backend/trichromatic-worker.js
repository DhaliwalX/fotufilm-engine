import { relatedAssetUrl } from "../runtime-assets.js";

// The measuring, registering and merging of a browser trichromatic merge
// (browser-trichromatic.js), off the page's thread, with the engine's scan module
// (FotufilmTrichromatic.h, built into negative/prepare.mjs). Layers travel as Blobs of raw floats.

const BLANK = 3;
let loading = null;

function load(url) {
  loading ??= import(/* @vite-ignore */ url).then(({ default: create }) =>
    create({ locateFile: (name) => relatedAssetUrl(name, url) }),
  );
  return loading;
}

// Room in the module's memory for `bytes`, freed after `body`.
function withHeap(module, sizes, body) {
  const blocks = sizes.map((size) => module._malloc(size));
  try {
    if (blocks.some((block) => !block)) throw new Error("Not enough memory to merge these exposures.");
    return body(...blocks);
  } finally {
    blocks.forEach((block) => module._free(block));
  }
}

// An exposure's light and colour, and its layer under that light when it is one of the three.
function read(module, { samples, width, height, rgb16 }) {
  if (typeof module._fotufilm_trichromatic_merge !== "function")
    throw new Error("The scan module is out of date. Rebuild it and reload the editor.");
  const count = width * height;
  return withHeap(module, [samples.byteLength, 20, 4 * count], (pixels, measured, plane) => {
    module.HEAPU8.set(new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength), pixels);
    const measure = rgb16 ? module._trichromatic_measure_rgb16 : module._fotufilm_trichromatic_measure;
    if (measure(pixels, width, height, measured, measured + 16))
      throw new Error("The exposure could not be read.");
    const colour = Array.from(module.HEAPF32.subarray(measured / 4, measured / 4 + 3));
    const light = module.HEAP32[(measured + 16) / 4];
    if (light < 0 || light >= BLANK) return { light, colour };
    const layer = rgb16 ? module._trichromatic_layer_rgb16 : module._fotufilm_trichromatic_layer;
    if (layer(pixels, width, height, measured, plane))
      throw new Error("The exposure could not be read.");
    return { light, colour, layer: new Blob([module.HEAPU8.subarray(plane, plane + 4 * count)]) };
  });
}

// Index triples (red, green, blue) into `lights`, or the index where the order breaks as -1 - i.
function group(module, { lights }) {
  const count = lights.length;
  return withHeap(module, [4 * Math.max(1, count), 4 * Math.max(3, count)], (input, output) => {
    module.HEAP32.set(lights, input / 4);
    const made = module._fotufilm_trichromatic_group(input, count, output);
    if (made < 0) return { broken: -1 - made };
    return {
      frames: Array.from({ length: made }, (_, f) =>
        Array.from(module.HEAP32.subarray(output / 4 + 3 * f, output / 4 + 3 * f + 3)),
      ),
    };
  });
}

async function layers(blobs) {
  return Promise.all(blobs.map(async (blob) => new Uint8Array(await blob.arrayBuffer())));
}

// Where the moving layer lies under the reference.
async function register(module, { reference, moving, width, height }) {
  const [a, b] = await layers([reference, moving]);
  return withHeap(module, [a.byteLength, b.byteLength, 24 + 12], (first, second, affine) => {
    module.HEAPU8.set(a, first);
    module.HEAPU8.set(b, second);
    const status = module._fotufilm_trichromatic_register(first, second, width, height, affine, affine + 24);
    if (status === -4)
      throw new Error(
        "The exposures share too little detail to line up: pick three exposures of the same frame.",
      );
    if (status) throw new Error("The exposures could not be merged.");
    return Array.from(module.HEAPF32.subarray(affine / 4, affine / 4 + 6));
  });
}

// The merged TIFF's bytes.
async function merge(module, { stored, width, height, green, blue }) {
  const planes = await layers(stored);
  const bytes = Number(module._fotufilm_trichromatic_file_size(width, height));
  return withHeap(module, [...planes.map((plane) => plane.byteLength), 48, bytes], (r, g, b, affines, file) => {
    [r, g, b].forEach((at, i) => module.HEAPU8.set(planes[i], at));
    module.HEAPF32.set([...green, ...blue], affines / 4);
    if (module._fotufilm_trichromatic_merge(r, g, b, width, height, affines, affines + 24, file, BigInt(bytes)))
      throw new Error("The exposures could not be merged.");
    return module.HEAPU8.slice(file, file + bytes).buffer;
  });
}

const tasks = { read, group, register, merge };

self.onmessage = async ({ data: { id, task, url, ...input } }) => {
  try {
    const result = await tasks[task](await load(url), input);
    self.postMessage({ id, result }, result instanceof ArrayBuffer ? [result] : []);
  } catch (error) {
    self.postMessage({ id, error: error?.message ?? String(error) });
  }
};
