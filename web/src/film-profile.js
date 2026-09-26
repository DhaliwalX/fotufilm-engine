import { assetUrl } from "./engine.js";

let worker,
  serial = 0;
const pending = new Map(),
  cache = new Map();

export function loadFilmProfile(request, onProgress = () => {}) {
  // Image analyses are one-shot; do not retain multi-megabyte scan data as cache keys.
  const key = ["negative-auto", "negative-film"].includes(request.kind)
    ? null
    : JSON.stringify(request);
  if (cache.has(key)) {
    const entry = cache.get(key);
    cache.delete(key);
    if (key !== null) cache.set(key, entry);
    if (!entry.done) {
      entry.listeners.add(onProgress);
      if (entry.status) onProgress(entry.status);
    }
    return entry.promise;
  }
  if (!worker) {
    worker = new Worker(new URL("./profile-worker.js", import.meta.url), {
      type: "module",
    });
    worker.onmessage = ({ data }) => {
      const request = pending.get(data.id);
      if (!request) return;
      if (data.status) return request.report(data.status);
      pending.delete(data.id);
      if (data.error) request.reject(new Error(data.error));
      else request.resolve(data.profile);
    };
    worker.onerror = () => {
      for (const request of pending.values())
        request.reject(new Error("Film profile worker failed."));
      pending.clear();
      cache.clear();
      worker.terminate();
      worker = null;
    };
  }
  const entry = { listeners: new Set([onProgress]), done: false, status: null };
  entry.promise = new Promise((resolve, reject) => {
    const id = ++serial;
    pending.set(id, {
      resolve,
      reject,
      report(status) {
        entry.status = status;
        for (const listener of entry.listeners) listener(status);
      },
    });
    worker.postMessage({ id, request, base: assetUrl("profile/") });
  })
    .catch((error) => {
      if (cache.get(key) === entry) cache.delete(key);
      throw error;
    })
    .finally(() => {
      entry.done = true;
      entry.listeners.clear();
    });
  if (key !== null) cache.set(key, entry);
  if (cache.size > 8) cache.delete(cache.keys().next().value);
  return entry.promise;
}
