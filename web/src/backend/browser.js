import { BACKEND_VERSION } from "./contract.js";
import { RenderSession, loadStockIndex } from "../render-session.js";
import { prepareEditor } from "./browser-prepare.js";
import { importMedia } from "./browser-import.js";
import { exportImage, exportVideo } from "./browser-export.js";
import { createHistogram } from "./browser-histogram.js";
import { analyseNegative, convertNegative } from "../negative-conversion.js";
import { attachLinearPreview } from "../linear-preview.js";
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
    importMedia,
    releaseImage: (image) => image?.video?.dispose(),
    analyseNegative,
    convertNegative,
    makePreview: attachLinearPreview,
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
