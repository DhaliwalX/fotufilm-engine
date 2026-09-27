import { profileRequestControls } from "../../profile-settings.js";
import { sourceIlluminant } from "../../editor-catalogue.js";
import { imageBlob } from "./transport.js";
import { frameRequest } from "../../print-frame.js";

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
  // Framed as the browser engine frames: the finished picture, not the crop tool, a pipeline
  // stage, a video frame or a film-strip thumbnail.
  const framed =
    edit.printFrame &&
    edit.printFrame !== "none" &&
    !cropMode &&
    stage == null &&
    !image.video &&
    !request.background;
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
    printFrame: framed ? frameRequest(edit) : null,
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
  let lastOriginal = null;
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
        const nativeRequest = {
          ...renderRequest(request, await catalogue()),
          haveOriginal: lastOriginal?.key,
        };
        const result = await call("render", nativeRequest, { signal: lifecycle.signal });
        // A host that knows the page holds this original leaves it out of the answer.
        const original = result.original != null
          ? imageBlob(result.original, result.previewType)
          : lastOriginal?.key === result.originalKey
            ? lastOriginal.blob
            : null;
        if (!original) throw new Error("The native host sent no original picture.");
        if (result.originalKey) lastOriginal = { key: result.originalKey, blob: original };
        if (lifecycle.signal.aborted || request.stale?.()) {
          resolve(null);
          continue;
        }
        resolve({
          ...result,
          preview: undefined,
          blob: imageBlob(result.preview, result.previewType),
          original,
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
