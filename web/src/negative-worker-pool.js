import { supportsWebgpuRuntime } from "./runtime-assets.js";

// An idle converter retains its WASM instance and compiled GPU pipelines.
// Each conversion checks out a worker exclusively; cancellation destroys it.
// A GPU call can suspend forever (seen on Android), so a warmup that stalls
// or falls back sends every later conversion to the CPU.
let idle, warming;
export const createNegativeWorker = () =>
  new Worker(new URL("./negative-conversion-worker.js", import.meta.url), {
    type: "module",
  });
export function takeNegativeWorker() {
  const worker = idle || createNegativeWorker();
  idle = null;
  return worker;
}
export function returnNegativeWorker(worker) {
  worker.onmessage = worker.onerror = null;
  if (idle) worker.terminate();
  else idle = worker;
}
// Resolves whether conversions should run on the GPU.
export function prepareNegativeWorker(base, { timeoutMs = 30000 } = {}) {
  if (warming) return warming;
  if (!supportsWebgpuRuntime(navigator.gpu, WebAssembly))
    return (warming = Promise.resolve(false));
  const worker = takeNegativeWorker();
  warming = new Promise((resolve) => {
    let settled = false;
    const finish = (gpu, reusable) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (reusable) returnNegativeWorker(worker);
      else worker.terminate();
      resolve(gpu);
    };
    const timer = setTimeout(() => {
      console.warn("Negative conversion GPU stalled; converting on the CPU.");
      finish(false, false);
    }, timeoutMs);
    worker.onerror = () => finish(false, false);
    worker.onmessage = ({ data }) => {
      if (data.kind === "done") finish(data.backend === "webgpu", true);
      else if (data.kind === "error") finish(false, false);
    };
    worker.postMessage({ kind: "warmup", base });
  });
  return warming;
}
