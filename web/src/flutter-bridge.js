// The browser engine for the Flutter editor (flutter/), answering the host calls a native host
// answers through fotufilm.h that a browser can (see `methods`) from the browser backend
// (backend/browser.js), so one Flutter UI runs on either engine. `capabilities` says what it
// offers, as the native host's capabilities do. Each answer is {json, payload?}: the payload's named byte ranges are listed
// under json.payloads, as the native host's are. Pictures come back as sRGB, which Flutter draws
// as it is.
import { DPX_TYPE } from "./dpx.js";
import { createBrowserBackend } from "./backend/browser.js";
import { defaultEdit } from "./editor-state.js";
import { loadFilmProfile } from "./film-profile.js";
import { download } from "./editor/file-download.js";
import { VIDEO_LABELS } from "./generated/controls.js";
import {
  chooseFolder,
  folderFile,
  forgetFolder,
  listFolder,
} from "./photo-library/browser-folders.js";
import { libraryThumbnail } from "./photo-library/library-thumbnails.js";

const backend = createBrowserBackend();
const session = backend.createSession();
const images = new Map();
let nextHandle = 1;
let stocks = null;
// Each photograph's last shown develop, which scene and film-base samples are read from.
const shown = new Map();
// The movie export running, stopped by cancel.
let videoExport = null;
// A cancel makes every develop asked for before it stale; the renderer then answers null.
let generation = 0;

class Cancelled extends Error {}

async function prepare() {
  await backend.prepare(session, () => {});
  stocks ??= await backend.loadStocks();
  return { json: { stocks: stocks.map((s) => s.id), catalogue: stocks } };
}

function capabilities() {
  return {
    json: {
      imageExportTypes: ["image/png", "image/tiff", "image/jpeg", "image/webp", DPX_TYPE],
      video: true,
      videoExportTypes: ["mp4", "webm"].map((id) => ({
        id,
        label: VIDEO_LABELS[id],
        extension: id,
        type: `video/${id}`,
        quality: true,
      })),
    },
  };
}

// A photo of a library folder comes by its path, the others as their bytes.
async function importFile({ name, type, path, negative = false }, bytes) {
  const file = bytes ? new File([bytes], name, { type: type || "" }) : await folderFile(path);
  const { image } = await backend.importMedia(file, { negative });
  const video = image.video ? await movieDescriptor(image.video) : null;
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
      ...(video ? { video } : {}),
      ...(image.negative ? { negative: image.negative } : {}),
    },
    { preview },
  );
}

/// The library's folders (photo-library/browser-folders.js): `path` is the folder's library name.
const libraryFolders = {
  chooseFolder: async () => ({ json: { path: await chooseFolder() } }),
  listFolder: async ({ path }) => ({ json: { rows: await listFolder(path) } }),
  forgetFolder: async ({ path }) => {
    await forgetFolder(path);
    return { json: {} };
  },
};

/// A library tile's picture of the file at `path`, as RGBA pixels (`thumbnail`).
async function thumbnail({ path, maxEdge = 480 }) {
  const drawn = await libraryThumbnail(await folderFile(path), maxEdge);
  if (!drawn) return { json: {} };
  return answer({ width: drawn.width, height: drawn.height }, { thumbnail: new Blob([drawn.pixels]) });
}

/// The app's edit over the browser's defaults: the native host defaults what an edit leaves out
/// (a movie's settings until one changes), and the browser session expects the whole edit.
function editOf(params) {
  const base = defaultEdit(params.edit.stock ?? null);
  return { ...base, ...params.edit, video: { ...base.video, ...params.edit.video } };
}

/// The clip as the native host describes it; the browser plays no sound of its own.
async function movieDescriptor(clip) {
  const stats = await clip.track.computePacketStats(120).catch(() => null);
  return {
    start: clip.start,
    duration: clip.duration,
    frameRate: stats?.averagePacketRate || 30,
    audio: false,
  };
}

/// A develop of the render request the app sends (renderRequest plus each tool's options).
async function develop(params, extra = {}) {
  const entry = imageFor(params.handle);
  const mine = generation;
  const stale = () => mine !== generation;
  const result = await session.render({
    image: entry.image,
    edit: editOf(params),
    stock: params.edit.stock,
    maxEdge: params.maxEdge ?? 1600,
    stage: params.stage ?? null,
    difference: params.difference === true,
    cropMode: params.cropMode === true,
    showMask: params.showMask === true,
    videoTime: params.videoTime ?? null,
    comparison: params.original === true,
    // The film rows and format tiles are background work: a preview goes ahead of them.
    background: params.original === false,
    colorSpace: "srgb",
    stale,
    ...extra,
  }).catch((error) => {
    // A develop interrupted by a cancel can fail on the way out; it was cancelled.
    throw stale() ? new Cancelled() : error;
  });
  if (!result) throw new Cancelled();
  return result;
}

async function render(params) {
  const result = await develop(params);
  if (params.original !== false) shown.set(params.handle, result);
  // The original only changes with the photograph, so it is sent once per handle.
  const key = `photo:${params.handle}`;
  const sendOriginal = params.original === true && params.haveOriginal !== key;
  return answer(
    {
      width: result.width,
      height: result.height,
      framePlan: result.framePlan ?? null,
      negativeMeasure: result.negativeMeasure ?? null,
      ...(sendOriginal && result.original ? { originalKey: key } : {}),
    },
    { preview: result.blob, original: sendOriginal ? result.original : null },
  );
}

async function autoAdjust({ handle, edit }) {
  const result = await backend.autoAdjust({
    image: imageFor(handle).image,
    edit: editOf({ edit }),
    session,
    onProgress: () => {},
  });
  return { json: result };
}

/// A develop to sample: the shown one, or a fresh one when the photograph has none yet.
async function sampled(request) {
  return shown.get(request.handle) ?? (await develop(request, { encode: false }));
}

async function sampleScene({ render: request, point }) {
  return { json: await backend.sampleScene(await sampled(request), point) };
}

async function negativeSampleFilmBase({ render: request, point }) {
  return { json: await backend.negativeScans.sampleFilmBase(await sampled(request), point) };
}

async function printFrame(request) {
  const plan = new TextDecoder().decode(
    await loadFilmProfile({
      ...request,
      format: request.format || null,
      medium: request.medium || null,
      viewingKelvin: request.viewingKelvin ?? null,
    }),
  );
  return { json: JSON.parse(plan) };
}

async function stages({ stock, medium, halationModel, digitalReference }) {
  return {
    json: await session.stages(
      stock,
      medium ?? null,
      halationModel ?? "legacy",
      digitalReference ?? "auto-levels",
    ),
  };
}

async function lensCatalogue() {
  return { json: (await backend.lenses.load()).profiles };
}

async function importLensCatalogue({ profiles }) {
  const file = new File([JSON.stringify(profiles)], "lenses.json", { type: "application/json" });
  return { json: await backend.lenses.import(file) };
}

async function removeLensCatalogue() {
  await backend.lenses.remove();
  return { json: {} };
}

async function lensPlan({ handle, lens }) {
  // The correction table is the engine's; the app shows the plan's note and measurement.
  const { table: _table, ...plan } = await backend.resolveLensPlan(imageFor(handle).image, lens);
  return { json: plan };
}

/// The browser writes no metadata and no HDR, and has no memory limit of its own to report. A
/// Cineon Log scan exports as DPX; the medium is offered only to negatives, which keep it.
function exportOptions(params) {
  const dpx = params?.edit?.medium === "cineon-log";
  return { json: { metadata: null, hdr: false, unavailable: [], dpx } };
}

async function exportImage(params) {
  const filename = params.filename || "fotufilm-export.jpg";
  await backend.exportImage({
    session,
    image: imageFor(params.handle).image,
    edit: editOf(params),
    stock: params.edit.stock,
    // No bound is the full picture; the session reads a missing one as no pixels at all.
    maxEdge: params.maxEdge ?? Infinity,
    type: params.type,
    quality: params.quality,
    metadata: params.metadata,
    filename,
    onProgress: () => {},
  });
  return { json: { filename, path: filename } };
}

async function exportVideo(params) {
  const filename = params.filename || "fotufilm-export.mp4";
  const controller = new AbortController();
  videoExport = controller;
  try {
    const saved = await backend.exportVideo({
      session,
      image: imageFor(params.handle).image,
      edit: editOf(params),
      stock: params.edit.stock,
      maxEdge: params.maxEdge ?? Infinity,
      format: params.format,
      quality: "high",
      filename,
      signal: controller.signal,
    });
    // Without a save panel the movie was written to the browser's own storage: download it.
    if (saved.url) {
      download(await (await fetch(saved.url)).blob(), filename);
      setTimeout(() => saved.dispose(), 60000);
    }
    return { json: { filename, path: filename } };
  } finally {
    if (videoExport === controller) videoExport = null;
  }
}

function release({ handle }) {
  const entry = images.get(handle);
  images.delete(handle);
  shown.delete(handle);
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
  capabilities,
  prepare,
  importFile,
  ...libraryFolders,
  thumbnail,
  render,
  autoAdjust,
  sampleScene,
  negativeSampleFilmBase,
  printFrame,
  stages,
  lensCatalogue,
  importLensCatalogue,
  removeLensCatalogue,
  lensPlan,
  exportOptions,
  export: exportImage,
  exportVideo,
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
    videoExport?.abort();
  },
});
