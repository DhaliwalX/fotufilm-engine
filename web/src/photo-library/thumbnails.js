import { runtimeAssetUrl } from "../runtime-assets.js";
import {
  loadThumbnails,
  saveThumbnail,
  trimThumbnails,
} from "./library-store.js";
import { currentFile } from "./library-scan.js";

// Tiles are at most ~240 CSS px; this keeps them sharp at 2x.
export const THUMBNAIL_EDGE = 480;
// Object URLs kept alive for tiles that scrolled away; older ones are revoked.
// Cached blobs are disk-backed, so this costs little memory.
const RETAINED = 1500;
// Thumbnails kept on disk, about 650 MB; checked every TRIM_EVERY new ones.
const STORED = 20000,
  TRIM_EVERY = 500;

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
    pending = new Map(),
    reads = new Map();
  let serial = 0,
    saves = 0,
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
  // Visible tiles jump the queue; prefetches wait behind everything else.
  function generate(photo, id, prefetch) {
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
      if (prefetch) queue.unshift(job);
      else queue.push(job);
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
  function readCached(key) {
    return new Promise((resolve) => {
      if (!reads.size)
        queueMicrotask(() => {
          const batch = [...reads];
          reads.clear();
          loadThumbnails(batch.map(([key]) => key)).then(
            (records) => batch.forEach(([, done], i) => done(records[i])),
            () => batch.forEach(([, done]) => done(null)),
          );
        });
      reads.set(key, resolve);
    });
  }
  // Resolves {blob, fresh}; fresh when generated now rather than read back.
  async function load(photo, entry, prefetch) {
    const cached = await readCached(photo.key);
    if (cached?.stamp === stamp(photo)) return { blob: cached.blob };
    if (entry.cancelled) return null;
    const result = await generate(photo, ++serial, prefetch);
    if (!result) return null;
    saveThumbnail({
      key: photo.key,
      stamp: stamp(photo),
      blob: result.blob,
    })
      .then(() => {
        if (++saves % TRIM_EVERY === 0) return trimThumbnails(STORED);
      })
      .catch(() => {});
    return { blob: result.blob, fresh: true };
  }

  return {
    // The URL of a thumbnail already in memory, without waiting.
    peek(photo) {
      return urls.get(`${photo.key}@${stamp(photo)}`) ?? null;
    },
    // Resolves {url, fresh}; url is null for formats with no quick preview
    // (EXR, raws without an embedded JPEG). `cancel` drops the request if it
    // has not started. A prefetch runs only when nothing visible is waiting.
    request(photo, { prefetch = false } = {}) {
      const key = `${photo.key}@${stamp(photo)}`;
      if (urls.has(key)) {
        const url = urls.get(key);
        retain(key, url);
        return { promise: Promise.resolve({ url }), cancel() {} };
      }
      let entry = pending.get(key);
      if (entry) {
        entry.cancelled = false;
        entry.wanted++;
        // A tile now needs what was prefetched: move it to the front.
        const index = prefetch
          ? -1
          : queue.findIndex((job) => job.photo.key === photo.key);
        if (index >= 0) queue.push(...queue.splice(index, 1));
      } else {
        entry = { cancelled: false, wanted: 1 };
        entry.promise = load(photo, entry, prefetch).then((loaded) => {
          if (pending.get(key) === entry) pending.delete(key);
          if (!loaded || disposed) return { url: null };
          const url = URL.createObjectURL(loaded.blob);
          retain(key, url);
          return { url, fresh: loaded.fresh };
        });
        pending.set(key, entry);
      }
      let cancelled = false;
      return {
        promise: entry.promise,
        // Only the last interested tile or prefetch stops the work.
        cancel() {
          if (cancelled || --entry.wanted > 0) return void (cancelled = true);
          cancelled = true;
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
