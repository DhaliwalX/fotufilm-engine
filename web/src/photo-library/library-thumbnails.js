// Small pictures of a library folder's files for the Flutter library's tiles, as RGBA: a still's
// embedded or reduced preview and a movie's first frame, drawn by a few workers
// (thumbnail-worker.js) with the Halide resampler; HEIC from its own thumbnail.
import { assetUrl } from "../engine.js";
import { libraryMediaKind } from "../media-types.js";
import { isHEIF } from "../heif.js";
import { heicThumbnail } from "../heic-import.js";

const WORKERS = Math.min(4, Math.max(2, (navigator.hardwareConcurrency || 4) >> 1));
const pool = [],
  queue = [];
let serial = 0;

function spawn() {
  const slot = {
    worker: new Worker(new URL("./thumbnail-worker.js", import.meta.url), { type: "module" }),
    job: null,
  };
  const finish = (result) => {
    const job = slot.job;
    slot.job = null;
    job?.done(result);
    pump();
  };
  slot.worker.onmessage = ({ data }) => {
    const job = slot.job;
    if (job?.id !== data.id) return;
    if (data.result?.fallback) {
      // WebCodecs could not decode this movie; a <video> element may.
      videoFrame(job.file).then((bitmap) =>
        bitmap
          ? slot.worker.postMessage({ ...job.message, file: null, bitmap }, [bitmap])
          : finish(null),
      );
      return;
    }
    finish(data.error ? null : data.result);
  };
  slot.worker.onerror = () => finish(null);
  return slot;
}

function pump() {
  while (queue.length) {
    let slot = pool.find((item) => !item.job);
    if (!slot && pool.length < WORKERS) pool.push((slot = spawn()));
    if (!slot) return;
    // The newest request is the tile just scrolled to.
    const job = queue.pop();
    slot.job = job;
    slot.worker.postMessage({ ...job.message, file: job.file });
  }
}

// A <video> element can only be read on the page's thread; the worker gets the frame.
function videoFrame(file) {
  return new Promise((resolve) => {
    const video = document.createElement("video"),
      url = URL.createObjectURL(file);
    const finish = (bitmap) => {
      clearTimeout(timer);
      video.removeAttribute("src");
      video.load();
      URL.revokeObjectURL(url);
      resolve(bitmap);
    };
    const timer = setTimeout(() => finish(null), 8000);
    video.muted = true;
    video.preload = "auto";
    video.onloadedmetadata = () => (video.currentTime = Math.min(1, (video.duration || 0) / 10));
    video.onseeked = () => createImageBitmap(video).then(finish, () => finish(null));
    video.onerror = () => finish(null);
    video.src = url;
  });
}

/// `{pixels, width, height}` (sRGB RGBA, the long edge at most `edge`), or null when nothing
/// could be drawn.
export async function libraryThumbnail(file, edge) {
  const kind = libraryMediaKind(file.name);
  if (!kind) return null;
  if (kind === "image" && isHEIF(new Uint8Array(await file.slice(0, 64).arrayBuffer())))
    return heicThumbnail(file, edge).catch(() => null);
  return new Promise((resolve) => {
    queue.push({
      id: ++serial,
      file,
      message: { id: serial, kind, edge, runtime: assetUrl("library/thumbnail.mjs") },
      done: resolve,
    });
    pump();
  });
}
