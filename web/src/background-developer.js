import { supportsWebgpuRuntime } from "./runtime-assets.js";
import { yieldToBrowser } from "./yield.js";

// Kernels, shader compilation, metering and output encoding run off the UI thread.
// Pull bounded source strips on demand; never clone the full-resolution photograph.
export async function createBackgroundDeveloper(
  pack,
  onProgress = () => {},
  onRendererReady = () => {},
  options = {},
) {
  const worker = new Worker(new URL("./developer-worker.js", import.meta.url), {
    type: "module",
  });
  let gpuReadyResolve;
  const gpuReady = new Promise((resolve) => {
    gpuReadyResolve = resolve;
  });
  let active,
    currentPack = pack,
    uploadedPack = pack,
    closed = false;
  const ready = new Promise((resolve, reject) => {
    active = { resolve, reject, onProgress };
  });
  const developer = {
    backend: null,
    gpuReady,
    usePack(next) {
      currentPack = next;
    },
    get isAborted() {
      return closed;
    },
    develop(
      source,
      controls,
      report = () => {},
      stale = () => false,
      output = {},
    ) {
      if (closed)
        return Promise.reject(
          new Error("The background image engine is closed."),
        );
      if (active)
        return Promise.reject(
          new Error("Image developments must be serialized."),
        );
      return new Promise((resolve, reject) => {
        active = { resolve, reject, source, onProgress: report, stale };
        worker.postMessage({
          kind: "develop",
          width: source.width,
          height: source.height,
          controls,
          output,
          packChanged: currentPack !== uploadedPack,
          pack: currentPack !== uploadedPack ? currentPack : null,
        });
        uploadedPack = currentPack;
      });
    },
    dispose() {
      closed = true;
      gpuReadyResolve(false);
      worker.terminate();
      active?.resolve(null);
      active = null;
    },
  };
  worker.onerror = (event) => {
    const pending = active;
    active = null;
    developer.dispose();
    pending?.reject(
      new Error(event.message || "The background image engine stopped."),
    );
  };
  worker.onmessage = async ({ data }) => {
    if (data.kind === "gpu-ready") {
      gpuReadyResolve(data.available);
      if (!closed && data.available) onRendererReady();
      return;
    }
    const job = active;
    if (!job || closed) return;
    if (data.kind === "ready") {
      developer.backend = data.backend;
      active = null;
      job.resolve(developer);
    } else if (data.kind === "progress") {
      if (job.stale?.()) worker.postMessage({ kind: "cancel" });
      else job.onProgress(data.text);
    } else if (data.kind === "read") {
      try {
        const { x, y, width, height } = data;
        let pixels;
        const strip = Math.max(1, Math.floor(32768 / width));
        for (let row = 0; row < height; row += strip) {
          if (closed) return;
          if (job.stale()) {
            worker.postMessage({ kind: "cancel" });
            worker.postMessage({
              kind: "pixels",
              id: data.id,
              error: "Preview superseded.",
            });
            return;
          }
          const chunk = job.source.read(
            x,
            y + row,
            width,
            Math.min(strip, height - row),
          );
          pixels ??= new chunk.constructor(width * height * 4);
          pixels.set(chunk, row * width * 4);
          await yieldToBrowser();
        }
        if (!closed)
          worker.postMessage({ kind: "pixels", id: data.id, pixels }, [
            pixels.buffer,
          ]);
      } catch (error) {
        if (!closed)
          worker.postMessage({
            kind: "pixels",
            id: data.id,
            error: error.message,
          });
      }
    } else if (data.kind === "result" || data.kind === "error") {
      active = null;
      if (job.stale?.()) job.resolve(null);
      else if (data.kind === "error") {
        if (data.fatal || !job.source) developer.dispose();
        job.reject(new Error(data.message));
      } else {
        developer.backend = data.backend;
        job.resolve(data.result);
      }
    }
  };
  worker.postMessage({
    kind: "initialize",
    pack,
    preferGpu:
      options.preferGpu !== false &&
      supportsWebgpuRuntime(navigator.gpu, WebAssembly),
  });
  return ready;
}
