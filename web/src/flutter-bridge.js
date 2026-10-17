// The browser engine for the Flutter editor (flutter/), answering the same host calls a native
// host answers through fotufilm.h — prepare, importFile, render, autoAdjust, export, release —
// from the browser backend the web editor uses (backend/browser.js), so one Flutter UI runs on
// either engine. Each answer is {json, payload?}: the payload's named byte ranges are listed
// under json.payloads, as the native host's are. Pictures come back as sRGB, which Flutter draws
// as it is.
import { createBrowserBackend } from "./backend/browser.js";

const backend = createBrowserBackend();
const session = backend.createSession();
const images = new Map();
let nextHandle = 1;
let stocks = null;
// A cancel makes every develop asked for before it stale; the renderer then answers null.
let generation = 0;

class Cancelled extends Error {}

async function prepare() {
  await backend.prepare(session, () => {});
  stocks ??= await backend.loadStocks();
  return { json: { stocks: stocks.map((s) => s.id), catalogue: stocks } };
}

async function importFile({ name, type, negative = false }, bytes) {
  const file = new File([bytes], name, { type: type || "" });
  const { image } = await backend.importMedia(file, { negative });
  const handle = nextHandle++;
  images.set(handle, { image, file });
  // A bounded picture for the strip and the library until the first develop.
  const preview = await backend
    .thumbnail({ file }, { maxEdge: 1024 })
    .then(async (url) => {
      if (!url) return null;
      const blob = await (await fetch(url)).blob();
      URL.revokeObjectURL(url);
      return blob;
    })
    .catch(() => null);
  return answer(
    {
      handle,
      naturalWidth: image.naturalWidth ?? image.width,
      naturalHeight: image.naturalHeight ?? image.height,
      identity: null,
      ...(image.raw ? { original: { name } } : {}),
    },
    { preview },
  );
}

async function render(params) {
  const entry = imageFor(params.handle);
  const mine = generation;
  const result = await session.render({
    image: entry.image,
    edit: params.edit,
    stock: params.edit.stock,
    maxEdge: params.maxEdge ?? 1600,
    comparison: params.original === true,
    // The film rows and format tiles are background work: a preview goes ahead of them.
    background: params.original === false,
    colorSpace: "srgb",
    stale: () => mine !== generation,
  });
  if (!result) throw new Cancelled();
  // The original only changes with the photograph, so it is sent once per handle.
  const key = `photo:${params.handle}`;
  const sendOriginal = params.original === true && params.haveOriginal !== key;
  return answer(
    {
      width: result.width,
      height: result.height,
      ...(sendOriginal && result.original ? { originalKey: key } : {}),
    },
    { preview: result.blob, original: sendOriginal ? result.original : null },
  );
}

async function autoAdjust({ handle, edit }) {
  const result = await backend.autoAdjust({
    image: imageFor(handle).image,
    edit,
    session,
    onProgress: () => {},
  });
  return { json: result };
}

async function exportImage(params) {
  const filename = params.filename || "fotufilm-export.jpg";
  await backend.exportImage({
    session,
    image: imageFor(params.handle).image,
    edit: params.edit,
    stock: params.edit.stock,
    maxEdge: params.maxEdge ?? null,
    type: params.type,
    quality: params.quality,
    metadata: params.metadata,
    filename,
    onProgress: () => {},
  });
  return { json: { filename, path: filename } };
}

function release({ handle }) {
  const entry = images.get(handle);
  images.delete(handle);
  if (entry) backend.releaseImage(entry.image);
  return { json: {} };
}

function imageFor(handle) {
  const entry = images.get(handle);
  if (!entry) throw new Error("That photograph is no longer open.");
  return entry;
}

/// Packs named blobs into one payload with their byte ranges, as the native host answers.
async function answer(json, blobs) {
  const parts = [];
  const payloads = {};
  let offset = 0;
  for (const [name, blob] of Object.entries(blobs)) {
    if (!blob) continue;
    const bytes = new Uint8Array(await blob.arrayBuffer());
    payloads[name] = [offset, bytes.length];
    parts.push(bytes);
    offset += bytes.length;
  }
  if (!parts.length) return { json };
  const payload = new Uint8Array(offset);
  let at = 0;
  for (const part of parts) {
    payload.set(part, at);
    at += part.length;
  }
  return { json: { ...json, payloads }, payload };
}

const methods = {
  prepare,
  importFile,
  render,
  autoAdjust,
  export: exportImage,
  release,
};

globalThis.fotufilmEngine = Object.freeze({
  /// Answers {json: string, payload?: Uint8Array}, or {error, cancelled} — never rejects.
  async call(method, paramsJSON, bytes) {
    try {
      const handler = methods[method];
      if (!handler) throw new Error(`The browser engine does not answer ${method}.`);
      const { json, payload } = await handler(JSON.parse(paramsJSON || "{}"), bytes);
      return { json: JSON.stringify(json), payload: payload ?? null };
    } catch (error) {
      const cancelled = error instanceof Cancelled || error?.name === "AbortError";
      return { error: error?.message || String(error), cancelled };
    }
  },
  cancel() {
    generation++;
  },
});
