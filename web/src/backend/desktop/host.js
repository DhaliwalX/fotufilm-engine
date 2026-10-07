import { appSetting } from "../../app-settings.js";
import { createLenses } from "./lenses.js";
import { frameRequest } from "../../print-frame.js";
import { isVideoFile } from "../../media-types.js";
import { importVideo, importedVideo } from "./video-import.js";
import { BACKEND_VERSION } from "../contract.js";
import { loadStockIndex } from "../../stock-index.js";
import { createHistogram } from "../../histogram-analyser.js";
import { createSession, renderRequest } from "./session.js";
import { createNegativeScans } from "./negative-scans.js";
import {
  createTransport,
  fileBase64,
  imageBlob,
  importedImage,
} from "./transport.js";

const EXPORT_LABELS = {
  "image/png": "PNG",
  "image/tiff": "TIFF · 16-bit",
  "image/jpeg": "JPEG",
  "image/heic": "HEIC",
};

export function createDesktopBackend(channel) {
  const call = createTransport(channel);
  // What the engine's platform services offer (fotufilm_capabilities); a host that does not say
  // offers only the contract's required methods.
  const can = channel.capabilities ?? {};
  // A host that states capabilities opens movies only when its engine has a video platform, and
  // its web view may not play their codecs, so the engine supplies the playback clock. One that
  // states none (WebKit's) answers the video calls itself and plays the file.
  const video = channel.capabilities ? can.video === true : true;
  const nativePlayback = channel.capabilities !== undefined;
  let ready, stocks;
  const prepare = () => (ready ??= call("prepare"));
  const catalogue = () =>
    (stocks ??= prepare().then(async (native) => {
      // A host that answers the film library itself needs none of the browser engine's files.
      if (native.catalogue?.length) return native.catalogue;
      const entries = await loadStockIndex();
      const available = entries.filter((stock) => native.stocks.includes(stock.id));
      if (!available.length)
        throw new Error("No matching native film definitions are installed.");
      return available;
    }));
  const releaseImage = (image) => {
    if (image?.video?.playbackUrl) URL.revokeObjectURL(image.video.playbackUrl);
    if (image?.handle)
      call("release", { handle: image.handle }).catch(console.error);
  };
  const lenses = createLenses(call);
  return {
    version: BACKEND_VERSION,
    createSession: () =>
      createSession(call, catalogue, { imageLayer: can.imageLayer === true }),
    // The host draws the photograph beneath the page: the canvas leaves its area transparent and
    // says where it is (web/src/backend/README.md, Native presentation).
    imageLayer: can.imageLayer === true,
    placeImageLayer: can.imageLayer
      ? (geometry) => call("setImageLayer", geometry).catch(() => {})
      : undefined,
    async prepare(session, report) {
      report({
        value: 10,
        label: "Connecting to native Halide/Metal",
        done: false,
      });
      await prepare();
      report({ value: 70, label: "Loading native films", done: false });
      await catalogue();
      session.onRendererReady?.();
      report({ value: 100, label: "Ready", done: true });
    },
    loadStocks: catalogue,
    async importMedia(file, { signal, negative, onProgress } = {}) {
      if (!negative && isVideoFile(file)) {
        if (!video) throw new Error("This host cannot open videos.");
        return importVideo(call, file, {
          signal,
          onProgress,
          binary: channel.binary === true,
          nativePlayback,
        });
      }
      onProgress?.("Opening with the native image decoder");
      const params = { name: file.name, negative: !!negative };
      if (channel.binary)
        return importedImage(
          await call("import", params, { signal, payload: await file.arrayBuffer() }),
        );
      const data = await fileBase64(file);
      return importedImage(await call("import", { ...params, data }, { signal }));
    },
    // A file the host chose (open panel, Finder, a drop) is read in place: no bytes cross.
    importPath: can.importPath
      ? async (path, { signal, negative, onProgress } = {}) => {
          onProgress?.("Opening with the native decoder");
          const result = await call(
            "importPath",
            { path, negative: !!negative, playback: nativePlayback },
            { signal },
          );
          // A movie opens in place too; its answer carries the playback clock. The identity is
          // what the file's edit is kept under (web/src/saved-edits.js).
          const { identity, ...answer } = result;
          const opened = answer.video ? importedVideo(answer) : importedImage(answer);
          return identity ? { ...opened, identity } : opened;
        }
      : undefined,
    releaseImage,
    // A file opened with others shows this in the strip until it is chosen (the embedded
    // preview where the file has one), so only the photograph being edited is decoded.
    thumbnail: can.thumbnails
      ? async ({ path, file }, { signal, maxEdge = 256 } = {}) => {
          if (!path && !channel.binary) return null;
          const result = await call(
            "thumbnail",
            path ? { path, maxEdge } : { name: file.name, maxEdge },
            { signal, payload: path ? undefined : await file.arrayBuffer() },
          );
          return URL.createObjectURL(imageBlob(result.thumbnail));
        }
      : undefined,
    // Every `maxEdge` is the long edge of the cropped picture, as the Mac app sizes previews and
    // exports.
    longEdgeOfCrop: true,
    // Scanned negatives: `importMedia`/`importPath` with `negative` open one as a document.
    negativeScans: can.negativeScans
      ? createNegativeScans(call, { binary: channel.binary === true })
      : undefined,
    subjectSelection: can.subjectSelection === true,
    previewBudget: can.previewBudget,
    // A picture the host presented never reached the page; the histogram asks for it.
    createHistogram: () => {
      const histogram = createHistogram();
      return {
        async analyse(result, options) {
          if (result.blob || !result.presented) return histogram.analyse(result, options);
          const answer = await call("presentedImage", {}, { signal: options?.signal });
          return histogram.analyse(
            { ...result, blob: imageBlob(answer.preview, answer.previewType) },
            options,
          );
        },
        dispose: () => histogram.dispose(),
      };
    },
    autoAdjust: async ({ image, edit, signal }) =>
      call("autoAdjust", { handle: image.handle, edit }, { signal }),
    planPrintFrame: (edit, width, height) => call("printFrame", frameRequest(edit, width, height)),
    resolveLensPlan: (image, lens) => call("lensPlan", { handle: image.handle, lens }),
    outputColorSpace: ({ type } = {}) => type === "image/webp" ? "srgb" : "display-p3",
    // The formats the engine's encoder writes; ImageIO has HEIC and no WebP encoder.
    imageExportTypes: (can.imageExportTypes ?? Object.keys(EXPORT_LABELS))
      .filter((id) => EXPORT_LABELS[id])
      .sort((a, b) => Object.keys(EXPORT_LABELS).indexOf(a) - Object.keys(EXPORT_LABELS).indexOf(b))
      .map((id) => ({ id, label: EXPORT_LABELS[id] })),
    sampleScene: (result, point) => call("sampleScene", { render: result.sceneRequest, point }),
    async exportImage(request) {
      request.onProgress?.("Rendering native export");
      return call("export", {
        ...renderRequest(request, await catalogue()),
        type: request.type,
        quality: request.quality,
        metadata: request.metadata,
        hdr: request.hdr === true,
        photoQuality: appSetting("photoQuality"),
        filename: request.filename,
      }, { signal: request.signal });
    },
    // A still export stops inside the engine when its signal aborts.
    exportImageCancels: true,
    // Export All: the photographs into one folder the host asks for, each with its own edit.
    // The engine decodes the next ones and writes the last ones while the current one develops.
    // An item is an open photograph (`image`) or a file not opened yet (`path`).
    exportImages: can.batchExport
      ? async ({ items, size, type, quality, metadata, hdr, signal, onProgress }) => {
          const stocks = await catalogue();
          return call("exportBatch", {
            items: items.map(({ image, path, name, filename, ...request }) => ({
              ...renderRequest({ ...request, image: image ?? {} }, stocks),
              ...(image ? {} : { path }),
              name,
              filename,
            })),
            size,
            type,
            quality,
            metadata,
            hdr: hdr === true,
            photoQuality: appSetting("photoQuality"),
          }, { signal, onProgress });
        }
      : undefined,
    // Whether a HEIC may carry HDR, where its film delivers it.
    hdrExport: can.hdrExport === true,
    // What each file's kept edit is stored under, for photographs not opened yet.
    fileIdentities: can.batchExport
      ? (paths) => call("fileIdentities", { paths }).then(({ identities }) => identities)
      : undefined,
    // Open or Show in Finder for a file an export just saved (`{filename, path}`).
    openExport: can.openExport
      ? (path, { reveal = false } = {}) => call("openExport", { path, reveal })
      : undefined,
    // What the host calls showing a file in its file manager.
    revealExportLabel: can.openExport?.reveal,
    // Export Original: a camera RAW opened from a file, copied as it is.
    exportOriginal: (image) =>
      call("exportOriginal", { handle: image.handle, filename: image.original.name, type: "" }),
    // What the native engine can write for this edit: metadata policies, HDR HEIC and the sizes
    // past its memory limit at this photo quality.
    exportOptions: can.imageExportTypes?.length
      ? async (request) =>
          call("exportOptions", {
            ...renderRequest(request, await catalogue()),
            sizes: (request.sizes ?? []).map(({ id, width, height }) => ({
              id,
              width: Math.round(width),
              height: Math.round(height),
            })),
            photoQuality: request.photoQuality ?? appSetting("photoQuality"),
          })
      : undefined,
    // Choose Film Per Photo: the engine ranks every film and learns the choices made.
    suggestFilm: can.filmSuggestion
      ? async (request) =>
          call("suggestFilm", {
            ...renderRequest(request, await catalogue()),
            photoID: request.photoID,
          })
      : undefined,
    recordFilmChoice: can.filmSuggestion
      ? (photoID, film) => call("recordFilmChoice", { photoID, film })
      : undefined,
    forgetFilmChoices: can.filmSuggestion ? () => call("forgetFilmChoices") : undefined,
    // The native open panel; what is chosen arrives as a native open ("fotufilm-native-open").
    openPanel: (kind = "all") => call("openPanel", { kind }),
    filmChoiceCount: can.filmSuggestion
      ? () => call("filmChoices").then(({ observations }) => observations)
      : undefined,
    // The developed frame on the system clipboard, written by the engine.
    copyImage: can.copyImage
      ? async (request) =>
          call("copyImage", {
            ...renderRequest(request, await catalogue()),
            photoQuality: appSetting("photoQuality"),
          })
      : undefined,
    // The plug-ins for other editors the engine's platform installs (DaVinci Resolve and Final
    // Cut Pro on the Mac), named up front; their state is read when asked.
    ...(can.plugins?.length
      ? {
          plugins: can.plugins.map(({ id, name }) => ({ id, name })),
          pluginStatus: () => call("plugins"),
          installPlugin: (id) => call("installPlugin", { id }),
          revealPlugin: (id) => call("revealPlugin", { id }),
        }
      : {}),
    // The movie formats the engine's platform writes (the Mac app's list); the editor's own
    // otherwise.
    videoExportTypes: video && can.videoExportTypes?.length ? can.videoExportTypes : undefined,
    // Video File Size choices, `{id, label}`, and the frame rates an export may retime to.
    videoBitrates: video && can.videoBitrates?.length ? can.videoBitrates : undefined,
    videoFrameRates: video && can.videoFrameRates?.length ? can.videoFrameRates : undefined,
    // Playback Quality: the engine plays a movie frame by frame, so the long edge it develops at
    // while playing is chosen, as the Mac app's preview offers it.
    playbackQuality: video && nativePlayback,
    // Video Quality, Full or Fast: offered where the engine's platform develops movies on a
    // pipeline with a reduced-size road.
    videoProcessing: video && can.videoProcessing === true,
    async exportVideo(request) {
      const format = can.videoExportTypes?.find(({ id }) => id === request.format);
      const saved = await call("exportVideo", {
        ...renderRequest(request, await catalogue()),
        format: request.format, bitrate: request.bitrate, filename: request.filename,
        videoProcessing: request.videoProcessing === "fast" ? "fast" : "full",
        type: format?.type ?? "video/mp4", hdr: request.hdr === true,
      }, { signal: request.signal, onProgress: request.onProgress });
      return { ...saved, dispose() {} };
    },
    // Check for Updates: the engine reads this app's release feed, and downloads, verifies and
    // opens the installer it names; with `prereleases`, the newest release's feed, pre-release
    // or not. Each call answers at once with where things stand
    // (`{state, current, version?, release?, notes?, bytes?, total?, message?}`).
    updates: can.updates
      ? {
          check: ({ prereleases = false } = {}) => call("updateCheck", { prereleases }),
          status: () => call("updateStatus"),
          install: () => call("updateInstall"),
          cancel: () => call("updateCancel"),
          notes: () => call("updateNotes"),
        }
      : undefined,
    // Import Film Pack: the engine installs community packs where this person's films live and
    // reloads its films; `reloadStocks` then makes the next `loadStocks` ask again.
    filmPacks: can.filmPacks
      ? {
          list: () => call("filmPacks"),
          importPath: (path) => call("importFilmPack", { path }),
          async importFile(file) {
            if (channel.binary)
              return call("importFilmPack", { name: file.name }, {
                payload: await file.arrayBuffer(),
              });
            return call("importFilmPack", { name: file.name, data: await fileBase64(file) });
          },
          remove: (packID) => call("removeFilmPack", { packID }),
        }
      : undefined,
    reloadStocks() {
      ready = stocks = undefined;
    },
    lenses,
  };
}
