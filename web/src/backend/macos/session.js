import { profileRequestControls } from "../../profile-settings.js";
import { sourceIlluminant } from "../../editor-catalogue.js";
import { imageBlob } from "./transport.js";

export function renderRequest(request, stocks) {
  const {
    image,
    edit,
    stock,
    maxEdge,
    viewport,
    videoTime,
    cropMode,
    comparison,
    stage,
    difference,
    showMask,
  } = request;
  const entry = stocks.find((item) => item.id === stock);
  return {
    handle: image.handle,
    previewQuality: image.video && request.interactive ? "playback" : "still",
    edit,
    maxEdge: Number.isFinite(maxEdge) ? maxEdge : null,
    viewport,
    videoTime,
    cropMode,
    comparison,
    stage,
    difference,
    showMask,
    profileRequest: {
      controls: {
        ...profileRequestControls(edit, entry),
        digitalReference: edit.digitalReference || "auto-levels",
      },
      format: edit.format,
      medium: edit.medium,
      sceneKelvin: sourceIlluminant(edit),
      filters: edit.filters,
      filterMetering: edit.filterMetering,
    },
  };
}

export function createSession(call, catalogue) {
  const lifecycle = new AbortController();
  const pending = [];
  let running = false;
  async function drain() {
    if (running) return;
    running = true;
    while (pending.length) {
      const foreground = pending.findIndex(
        ({ request }) => !request.background,
      );
      const { request, resolve, reject } = pending.splice(
        Math.max(0, foreground),
        1,
      )[0];
      if (lifecycle.signal.aborted || request.stale?.()) {
        resolve(null);
        continue;
      }
      try {
        request.onProgress?.("Developing with native Halide/Metal");
        const nativeRequest = renderRequest(request, await catalogue());
        const result = await call(
          "render",
          nativeRequest,
          { signal: lifecycle.signal },
        );
        if (lifecycle.signal.aborted || request.stale?.()) {
          resolve(null);
          continue;
        }
        resolve({
          ...result,
          preview: undefined,
          blob: imageBlob(result.preview, result.previewType),
          original: imageBlob(result.original, result.previewType),
          viewport: request.viewport,
          sceneRequest: nativeRequest,
        });
      } catch (error) {
        if (lifecycle.signal.aborted || request.stale?.()) resolve(null);
        else reject(error);
      }
    }
    running = false;
  }
  return {
    render(request) {
      return new Promise((resolve, reject) => {
        pending.push({ request, resolve, reject });
        drain();
      });
    },
    stages(stock, medium, halationModel, digitalReference) {
      return call("stages", { stock, medium, halationModel, digitalReference }, { signal: lifecycle.signal });
    },
    dispose() {
      lifecycle.abort();
      for (const job of pending.splice(0)) job.resolve(null);
    },
  };
}
