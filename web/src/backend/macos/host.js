import { createLenses } from "./lenses.js";
import { frameRequest } from "../../print-frame.js";
import { isVideoFile } from "../../media-types.js";
import { importVideo } from "./video-import.js";
import { BACKEND_VERSION } from "../contract.js";
import { loadStockIndex } from "../../stock-index.js";
import { createHistogram } from "../../histogram-analyser.js";
import { createSession, renderRequest } from "./session.js";
import {
  createTransport,
  fileBase64,
  importedImage,
} from "./transport.js";

export function createMacBackend(channel) {
  const call = createTransport(channel);
  let ready, stocks;
  const prepare = () => (ready ??= call("prepare"));
  const catalogue = () =>
    (stocks ??= Promise.all([prepare(), loadStockIndex()]).then(
      ([native, entries]) => {
        const available = entries.filter((stock) =>
          native.stocks.includes(stock.id),
        );
        if (!available.length)
          throw new Error("No matching native film definitions are installed.");
        return available;
      },
    ));
  const releaseImage = (image) => {
    if (image?.video?.playbackUrl) URL.revokeObjectURL(image.video.playbackUrl);
    if (image?.handle)
      call("release", { handle: image.handle }).catch(console.error);
  };
  const lenses = createLenses(call);
  return {
    version: BACKEND_VERSION,
    createSession: () => createSession(call, catalogue),
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
      if (!negative && isVideoFile(file))
        return importVideo(call, file, { signal, onProgress });
      onProgress?.("Opening with the native image decoder");
      const data = await fileBase64(file);
      return importedImage(
        await call(
          "import",
          { data, name: file.name, negative: !!negative },
          { signal },
        ),
      );
    },
    releaseImage,
    analyseNegative: (image, monochrome) =>
      call("analyseNegative", { handle: image.handle, monochrome }),
    async convertNegative(image, plan, { signal, maxEdge, onProgress } = {}) {
      onProgress?.({ progress: 0 });
      const result = await call(
        "convertNegative",
        {
          handle: image.handle,
          nativePlan: plan.nativePlan,
          maxEdge: Number.isFinite(maxEdge) ? maxEdge : null,
        },
        { signal },
      );
      // Preview URL ownership begins only in makePreview, after the scope owns this lease.
      const { preview, ...descriptor } = result;
      onProgress?.({ progress: 1 });
      return { image: { ...descriptor, linear: true }, backend: "Halide" };
    },
    async makePreview(image, { signal } = {}) {
      const result = await call(
        "preview",
        { handle: image.handle },
        { signal },
      );
      const preview = importedImage({ ...image, ...result });
      Object.assign(image, preview.image);
      return { image, url: preview.url };
    },
    createHistogram,
    autoAdjust: async ({ image, edit, signal }) =>
      call("autoAdjust", { handle: image.handle, edit }, { signal }),
    planPrintFrame: (edit, width, height) => call("printFrame", frameRequest(edit, width, height)),
    resolveLensPlan: (image, lens) => call("lensPlan", { handle: image.handle, lens }),
    outputColorSpace: ({ type } = {}) => type === "image/webp" ? "srgb" : "display-p3",
    sampleScene: (result, point) => call("sampleScene", { render: result.sceneRequest, point }),
    async exportImage(request) {
      request.onProgress?.("Rendering native export");
      return call("export", {
        ...renderRequest(request, await catalogue()),
        type: request.type,
        quality: request.quality,
        filename: request.filename,
      });
    },
    async exportVideo(request) {
      const saved = await call("exportVideo", {
        ...renderRequest(request, await catalogue()),
        format: request.format, quality: request.quality, filename: request.filename,
      }, { signal: request.signal, onProgress: request.onProgress });
      return { ...saved, dispose() {} };
    },
    lenses,
  };
}
