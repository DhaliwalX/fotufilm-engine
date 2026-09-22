import { supportsWebgpuRuntime } from "./runtime-assets.js";

// An idle converter retains its WASM instance and compiled GPU pipelines.
// Each conversion checks out a worker exclusively; cancellation destroys it.
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
export function prepareNegativeWorker(base) {
  if (warming) return warming;
  if (!supportsWebgpuRuntime(navigator.gpu, WebAssembly))
    return Promise.resolve(false);
  const worker = takeNegativeWorker();
  warming = new Promise((resolve) => {
    let settled = false;
    const finish = (available) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (available) returnNegativeWorker(worker);
      else worker.terminate();
      resolve(available);
    };
    const timer = setTimeout(() => finish(false), 180000);
    worker.onerror = () => finish(false);
    worker.onmessage = ({ data }) => {
      if (data.kind === "done") finish(data.backend === "webgpu");
      else if (data.kind === "error") finish(false);
    };
    worker.postMessage({ kind: "warmup", base });
  });
  return warming;
}
