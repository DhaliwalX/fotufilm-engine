import { relatedAssetUrl, supportsWebgpuRuntime } from "./runtime-assets.js";

let serial = 0;
const waiting = new Map();
self.onmessage = async ({ data }) => {
  if (data.kind === "pixels") {
    const pending = waiting.get(data.id);
    waiting.delete(data.id);
    if (data.error) pending?.reject(new Error(data.error));
    else pending?.resolve(data.pixels);
    return;
  }
  if (data.kind !== "convert") return;
  let runtime, input, output, parameters;
  function release() {
    if (!runtime) return;
    runtime._free(input);
    runtime._free(output);
    runtime._free(parameters);
    runtime = null;
    input = output = parameters = 0;
  }
  async function initialize(gpu) {
    const url = relatedAssetUrl(`${gpu ? "gpu" : "cpu"}.mjs`, data.base);
    const { default: create } = await import(/* @vite-ignore */ url);
    runtime = await create({
      locateFile: (name) => relatedAssetUrl(name, data.base),
    });
    input = runtime._malloc(512 * 512 * 3 * 4);
    output = runtime._malloc(512 * 512 * 3 * 4);
    parameters = runtime._malloc(8 * 4);
    if (!input || !output || !parameters)
      throw new Error("Not enough memory to convert this negative.");
    runtime.HEAPF32.set(data.parameters, parameters / 4);
  }
  try {
    let gpu =
      data.preferGpu !== false &&
      supportsWebgpuRuntime(navigator.gpu, WebAssembly);
    try {
      await initialize(gpu);
    } catch (error) {
      if (!gpu) throw error;
      release();
      gpu = false;
      await initialize(false);
    }
    const result = new Float32Array(data.width * data.height * 4);
    for (let y = 0; y < data.height; y += 512) {
      const h = Math.min(512, data.height - y);
      for (let x = 0; x < data.width; x += 512) {
        const w = Math.min(512, data.width - x),
          count = w * h;
        const pixels = await new Promise((resolve, reject) => {
          const id = ++serial;
          waiting.set(id, { resolve, reject });
          self.postMessage({ kind: "read", id, x, y, width: w, height: h });
        });
        const upload = () => {
          for (let c = 0; c < 3; c++)
            for (let i = 0; i < count; i++)
              runtime.HEAPF32[input / 4 + c * count + i] = pixels[i * 4 + c];
        };
        upload();
        let code;
        try {
          code = await runtime._negative_convert(
            input,
            output,
            w,
            h,
            parameters,
          );
        } catch (error) {
          if (!gpu) throw error;
          code = -1;
        }
        if (code && gpu) {
          release();
          gpu = false;
          await initialize(false);
          upload();
          code = await runtime._negative_convert(
            input,
            output,
            w,
            h,
            parameters,
          );
        }
        if (code) throw new Error(`Negative conversion failed (${code}).`);
        for (let row = 0; row < h; row++)
          for (let col = 0; col < w; col++) {
            const i = row * w + col,
              destination = ((y + row) * data.width + x + col) * 4;
            for (let c = 0; c < 3; c++)
              result[destination + c] =
                runtime.HEAPF32[output / 4 + c * count + i];
            result[destination + 3] = 1;
          }
      }
      self.postMessage({
        kind: "progress",
        progress: Math.min(1, (y + h) / data.height),
        backend: gpu ? "webgpu" : "cpu",
      });
    }
    self.postMessage(
      { kind: "done", pixels: result, backend: gpu ? "webgpu" : "cpu" },
      [result.buffer],
    );
  } catch (error) {
    self.postMessage({ kind: "error", error: error.message });
  } finally {
    release();
  }
};
