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
    // A movie playing without the comparison shown, as the Mac app plays one, leaves its
    // undeveloped frame undrawn.
    original: !(image.video && request.interactive) || !!request.compare,
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
  // The renders the host is developing, which a newer request cancels once they have gone
  // stale: a settled refinement never holds up the next edit's draft.
  const developing = new Set();
  let lastOriginal = null;
  // A playing movie keeps its next frame waiting at the host while the last one comes back, so
  // the host starts it the moment it is free. Anything else waits for the host to be idle.
  const playing = (request) => !!request.image?.video && !!request.interactive;
  // Film-strip thumbnails and other background pictures wait while a movie plays, as the Mac
  // app's never share its playback queue: one would hold the next frame back by a develop.
  let moviePlaying = false;
  const startable = (request) =>
    developing.size === 0 ||
    (developing.size === 1 &&
      playing(request) &&
      [...developing].every((entry) => playing(entry.request)));
  function drain() {
    while (pending.length) {
      const foreground = pending.findIndex(({ request }) => !request.background);
      if (foreground < 0 && moviePlaying) return;
      const index = Math.max(0, foreground);
      if (!startable(pending[index].request)) return;
      develop(pending.splice(index, 1)[0]);
    }
  }
  async function develop({ request, resolve, reject }) {
    if (lifecycle.signal.aborted || request.stale?.()) {
      resolve(null);
      return;
    }
    const entry = { request, controller: new AbortController() };
    developing.add(entry);
    try {
      request.onProgress?.("Developing with native Halide/Metal");
      const present = imageLayer ? presentRequest(request) : undefined;
      const nativeRequest = {
        ...renderRequest(request, await catalogue()),
        haveOriginal: lastOriginal?.key,
        ...(present ? { present } : {}),
      };
      const result = await call("render", nativeRequest, {
        signal: AbortSignal.any([lifecycle.signal, entry.controller.signal]),
      });
      // Shown by the host's compositor: the answer names frames, and no picture crossed.
      if (result.presented) {
        resolve(
          lifecycle.signal.aborted || request.stale?.()
            ? null
            : { ...result, viewport: request.viewport, sceneRequest: nativeRequest },
        );
        return;
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
        return;
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
      developing.delete(entry);
      drain();
    }
  }
  return {
    render(request) {
      return new Promise((resolve, reject) => {
        pending.push({ request, resolve, reject });
        if (!request.background) moviePlaying = playing(request);
        for (const entry of developing)
          if (entry.request.stale?.()) entry.controller.abort();
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
