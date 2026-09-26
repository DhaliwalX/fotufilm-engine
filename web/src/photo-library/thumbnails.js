import { runtimeAssetUrl } from "../runtime-assets.js";
import { loadThumbnail, saveThumbnail } from "./library-store.js";
import { currentFile } from "./library-scan.js";

// Tiles are at most ~240 CSS px; this keeps them sharp at 2x.
export const THUMBNAIL_EDGE = 480;
// Object URLs kept alive for tiles that scrolled away; older ones are revoked.
const RETAINED = 600;

const runtimeUrl = () =>
  runtimeAssetUrl(
    "library/thumbnail.mjs",
    import.meta.env.BASE_URL,
    globalThis.location.href,
    typeof __FOTUFILM_RUNTIME_REVISION__ === "string"
      ? __FOTUFILM_RUNTIME_REVISION__
      : "",
  );

// Fallback for videos WebCodecs cannot decode. A <video> element can only be
// read on the main thread; the worker gets the frame.
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
    video.onloadedmetadata = () =>
      (video.currentTime = Math.min(1, (video.duration || 0) / 10));
    video.onseeked = () =>
      createImageBitmap(video).then(finish, () => finish(null));
    video.onerror = () => finish(null);
    video.src = url;
  });
}

// Workers decode and resample; the newest request runs first, because it is the
// tile the user just scrolled to. Results are cached in the library database under
// the file's size and date, so a replaced file gets a new thumbnail.
export function createThumbnails({
  workers = Math.min(4, Math.max(2, (navigator.hardwareConcurrency || 4) >> 1)),
} = {}) {
  const pool = [],
    queue = [],
    urls = new Map(),
    pending = new Map();
  let serial = 0,
    disposed = false;
  const stamp = (photo) => `${photo.size}:${photo.modified}`;

  function spawn() {
    const worker = new Worker(
      new URL("./thumbnail-worker.js", import.meta.url),
      {
        type: "module",
      },
    );
    const slot = { worker, job: null };
    worker.onmessage = ({ data }) => {
      const job = slot.job;
      if (job?.id === data.id && data.result?.fallback) {
        // WebCodecs could not decode this video; a <video> element may.
        videoFrame(job.file).then((bitmap) => {
          if (bitmap && slot.job === job)
            worker.postMessage({ ...job.message, file: null, bitmap }, [
              bitmap,
            ]);
          else finish(job);
        });
        return;
      }
      finish(job, data.error ? null : data.result);
    };
    const finish = (job, result = null) => {
      if (slot.job === job) slot.job = null;
      job?.done(result);
      pump();
    };
    worker.onerror = () => {
      slot.job?.done(null);
      slot.job = null;
      pump();
    };
    return slot;
  }
  function pump() {
    if (disposed) return;
    while (queue.length) {
      let slot = pool.find((item) => !item.job);
      if (!slot && pool.length < workers) pool.push((slot = spawn()));
      if (!slot) return;
      const job = queue.pop();
      slot.job = job;
      job.start().then(
        (message) => {
          if (message)
            slot.worker.postMessage(
              message,
              message.bitmap ? [message.bitmap] : [],
            );
          else {
            slot.job = null;
            job.done(null);
            pump();
          }
        },
        () => {
          slot.job = null;
          job.done(null);
          pump();
        },
      );
    }
  }
  function generate(photo, id) {
    return new Promise((resolve) => {
      const job = {
        id,
        photo,
        async start() {
          job.file = await currentFile(photo);
          job.message = {
            id,
            kind: photo.kind,
            edge: THUMBNAIL_EDGE,
            runtime: runtimeUrl(),
          };
          return { ...job.message, file: job.file };
        },
        done: resolve,
      };
      queue.push(job);
      pump();
    });
  }
  function retain(key, url) {
    urls.delete(key);
    urls.set(key, url);
    for (const [old, value] of urls) {
      if (urls.size <= RETAINED) break;
      urls.delete(old);
      URL.revokeObjectURL(value);
    }
  }
  async function load(photo, entry) {
    const cached = await loadThumbnail(photo.key).catch(() => null);
    if (cached?.stamp === stamp(photo)) return cached.blob;
    if (entry.cancelled) return null;
    const result = await generate(photo, ++serial);
    if (!result) return null;
    saveThumbnail({
      key: photo.key,
      stamp: stamp(photo),
      blob: result.blob,
    }).catch(() => {});
    return result.blob;
  }

  return {
    // The URL of a thumbnail already in memory, without waiting.
    peek(photo) {
      return urls.get(`${photo.key}@${stamp(photo)}`) ?? null;
    },
    // An object URL, or null for formats with no quick preview (EXR, raws
    // without an embedded JPEG). `cancel` drops the request if it has not started.
    request(photo) {
      const key = `${photo.key}@${stamp(photo)}`;
      if (urls.has(key)) {
        const url = urls.get(key);
        retain(key, url);
        return { promise: Promise.resolve(url), cancel() {} };
      }
      let entry = pending.get(key);
      if (entry) entry.cancelled = false;
      else {
        entry = { cancelled: false };
        entry.promise = load(photo, entry).then((blob) => {
          if (pending.get(key) === entry) pending.delete(key);
          if (!blob || disposed) return null;
          const url = URL.createObjectURL(blob);
          retain(key, url);
          return url;
        });
        pending.set(key, entry);
      }
      return {
        promise: entry.promise,
        cancel() {
          entry.cancelled = true;
          const index = queue.findIndex((job) => job.photo.key === photo.key);
          if (index < 0) return;
          pending.delete(key);
          queue.splice(index, 1)[0].done(null);
        },
      };
    },
    dispose() {
      disposed = true;
      for (const job of queue.splice(0)) job.done(null);
      for (const slot of pool) slot.worker.terminate();
      for (const url of urls.values()) URL.revokeObjectURL(url);
      urls.clear();
    },
  };
}
