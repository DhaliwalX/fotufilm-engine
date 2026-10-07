import { BACKEND_VERSION } from "./contract.js";
import { RenderSession, loadStockIndex } from "../render-session.js";
import { prepareEditor } from "./browser-prepare.js";
import { importNegativeMedia, negativeScans } from "./browser-negative.js";
import { thumbnail } from "./browser-thumbnail.js";
import { exportImage, exportVideo } from "./browser-export.js";
import { createHistogram } from "./browser-histogram.js";
import { solveAutoAdjustment } from "./browser-auto-adjustment.js";
import { loadPrintFrame } from "./browser-print-frame.js";
import { sampleScene } from "./browser-selective.js";
import { resolveLensPlan } from "../lens-plan.js";
import { preferredCanvasColorSpace } from "../canvas-color.js";
import * as lenses from "../lens-catalogue.js";

export function createBrowserBackend() {
  return Object.freeze({
    version: BACKEND_VERSION,
    kind: "browser",
    createSession: () => new RenderSession(),
    prepare: prepareEditor,
    loadStocks: loadStockIndex,
    importMedia: importNegativeMedia,
    thumbnail,
    releaseImage: (image) => image?.video?.dispose(),
    negativeScans,
    createHistogram,
    autoAdjust: solveAutoAdjustment,
    planPrintFrame: loadPrintFrame,
    resolveLensPlan,
    outputColorSpace: preferredCanvasColorSpace,
    sampleScene: (result, point) =>
      result?.sceneSource ? sampleScene(result.sceneSource, point) : null,
    exportImage,
    exportVideo,
    lenses: Object.freeze({
      snapshot: lenses.lensCatalogueSnapshot,
      subscribe: lenses.subscribeLensCatalogue,
      load: lenses.loadLensCatalogue,
      import: lenses.importLensCatalogue,
      remove: lenses.removeLensCatalogue,
    }),
  });
}
