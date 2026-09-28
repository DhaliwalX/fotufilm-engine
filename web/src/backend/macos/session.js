import { profileRequestControls } from "../../profile-settings.js";
import { sourceIlluminant } from "../../editor-catalogue.js";
import { imageBlob } from "./transport.js";
import { frameRequest } from "../../print-frame.js";

// Where a render goes when the host draws the photograph itself: the layer ("preview" or
// "detail") and a scope naming what the page shows there, so the host may put a newer frame of
// the same size and scope on screen before the page has placed it. A tile's scope is its region.
export function presentRequest(request) {
  if (!request.present) return undefined;
  const scope = [request.image.handle, request.cropMode ? "crop" : "photo", request.stage ?? ""];
  if (request.present === "detail") scope.push(JSON.stringify(request.viewport ?? null));
  return { slot: request.present, scope: scope.join("|") };
}

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
    // A picture on its way to a settled one — a moving edit's preview, a film-strip thumbnail —
    // may be reduced from a smaller copy of the photograph, as the Mac app's drafts are.
    draft: !image.video && !!(request.interactive || request.background),
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

export function createSession(call, catalogue, { imageLayer = false } = {}) {
  const lifecycle = new AbortController();
  const pending = [];
  let running = false;
  // The render the host is developing, which a newer request cancels once it has gone stale: a
  // settled refinement never holds up the next edit's draft.
  let developing = null;
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
        const present = imageLayer ? presentRequest(request) : undefined;
        const nativeRequest = {
          ...renderRequest(request, await catalogue()),
          haveOriginal: lastOriginal?.key,
          ...(present ? { present } : {}),
        };
        developing = { request, controller: new AbortController() };
        const result = await call("render", nativeRequest, {
          signal: AbortSignal.any([lifecycle.signal, developing.controller.signal]),
        });
        // Shown by the host's compositor: the answer names frames, and no picture crossed.
        if (result.presented) {
          resolve(
            lifecycle.signal.aborted || request.stale?.()
              ? null
              : { ...result, viewport: request.viewport, sceneRequest: nativeRequest },
          );
          continue;
        }
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
      } finally {
        developing = null;
      }
    }
    running = false;
  }
  return {
    render(request) {
      return new Promise((resolve, reject) => {
        pending.push({ request, resolve, reject });
        if (developing?.request.stale?.()) developing.controller.abort();
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
