import {
  createDeveloper,
  createCpuDeveloper,
  developNormalReference,
  normalPack,
} from "./engine.js";

let cpu,
  gpu,
  pack,
  preferGpu,
  warming = false,
  cancelled = false,
  nextRead = 0;
const readyFamilies = new Set(),
  reads = new Map();
const family = (pack) =>
  pack.featureMask === 1 << 29
    ? "normal"
    : pack.featureMask & (1 << 7)
      ? "monochrome"
      : "color";
const gpuCompatible = (pack) =>
  !pack.transport && !(pack.featureMask & (1 << 28));

// Compile once per kernel family, using separate CPU/GPU heaps. CPU frames keep
// flowing while JSPI awaits GPU compilation; never change a GPU pack mid-dispatch.
async function warm(next) {
  if (
    !preferGpu ||
    warming ||
    !gpuCompatible(next) ||
    readyFamilies.has(family(next))
  )
    return;
  warming = true;
  try {
    if (!gpu) gpu = await createDeveloper(next);
    else {
      gpu.usePack(next);
      await gpu.probe();
    }
    if (gpu.backend !== "webgpu") {
      gpu.dispose();
      gpu = null;
      preferGpu = false;
    } else readyFamilies.add(family(next));
  } catch (error) {
    console.warn(
      "GPU warm-up failed; continuing background CPU development:",
      error,
    );
    gpu?.dispose();
    gpu = null;
    preferGpu = false;
  } finally {
    warming = false;
    self.postMessage({ kind: "gpu-ready", available: !!gpu });
  }
}
async function cpuFor(next) {
  if (cpu && !!cpu.pack?.transport !== !!next.transport) {
    cpu.dispose?.();
    cpu = null;
  }
  if (!cpu) {
    try {
      cpu = await createCpuDeveloper(next);
    } catch (error) {
      if (next.featureMask !== 1 << 29) throw error;
      cpu = { backend: "reference", develop: developNormalReference };
    }
  } else if (cpu.usePack) cpu.usePack(next);
  else if (next.featureMask !== 1 << 29) {
    cpu = await createCpuDeveloper(next);
  }
  return cpu;
}
self.onmessage = async ({ data }) => {
  if (data.kind === "pixels") {
    const read = reads.get(data.id);
    reads.delete(data.id);
    if (data.error) read?.reject(new Error(data.error));
    else read?.resolve(data.pixels);
    return;
  }
  if (data.kind === "cancel") {
    cancelled = true;
    return;
  }
  try {
    if (data.kind === "initialize") {
      pack = data.pack || normalPack();
      preferGpu = data.preferGpu;
      await cpuFor(pack);
      self.postMessage({ kind: "ready", backend: cpu.backend });
      if (preferGpu) void warm(pack);
      else self.postMessage({ kind: "gpu-ready", available: false });
    } else if (data.kind === "develop") {
      cancelled = false;
      if (data.packChanged) pack = data.pack || normalPack();
      const source = {
        width: data.width,
        height: data.height,
        read(x, y, width, height) {
          const id = ++nextRead;
          return new Promise((resolve, reject) => {
            reads.set(id, { resolve, reject });
            self.postMessage({ kind: "read", id, x, y, width, height });
          });
        },
      };
      let developer;
      if (
        gpu &&
        !warming &&
        gpuCompatible(pack) &&
        readyFamilies.has(family(pack))
      ) {
        developer = gpu;
        developer.usePack(pack);
      } else {
        developer = await cpuFor(pack);
        void warm(pack);
      }
      let result;
      try {
        result = await developer.develop(
          source,
          data.controls,
          progress,
          () => cancelled,
          data.output,
        );
      } catch (error) {
        if (developer !== gpu || cancelled) throw error;
        console.warn("GPU development failed; continuing on the CPU:", error);
        gpu?.dispose();
        gpu = null;
        preferGpu = false;
        developer = await cpuFor(pack);
        result = await developer.develop(
          source,
          data.controls,
          progress,
          () => cancelled,
          data.output,
        );
      }
      self.postMessage(
        { kind: "result", result, backend: developer.backend },
        result ? [result.pixels.buffer] : [],
      );
    }
  } catch (error) {
    self.postMessage({
      kind: "error",
      message: error.message,
      fatal: !cpu || cpu.isAborted,
    });
  }
};
function progress(text) {
  self.postMessage({ kind: "progress", text });
}
