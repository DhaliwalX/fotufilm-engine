import { useMemo } from "react";
import { outputSize } from "../geometry.js";
import { usePrintFrame } from "../usePrintFrame.js";
import { readsNegative } from "../negative-document.js";
import { exportBasis, exportMaxEdge, exportPixels } from "../export-sizes.js";
// The same size as the last render's keeps its identity, so what reads it is not rendered again.
function useSize(size) {
  const { width, height } = size;
  // eslint-disable-next-line react-hooks/exhaustive-deps
  return useMemo(() => size, [width, height]);
}

export default function useOutputState({
  backend,
  stocks,
  search,
  active,
  edit,
  exportSize,
  fixedSettings,
  result,
  activeId,
  setParam,
  endEdit,
  exporting,
}) {
  // A negative is read only as a film that has a negative.
  const libraryStocks = useMemo(
    () => (edit.negative ? stocks.filter(readsNegative) : stocks),
    [stocks, edit.negative],
  );
  const visibleStocks = useMemo(
    () =>
      libraryStocks.filter((stock) => stock.name.toLowerCase().includes(search.toLowerCase())),
    [libraryStocks, search],
  );
  const rawWidth = active?.image.naturalWidth || 0,
    rawHeight = active?.image.naturalHeight || 0;
  const width = edit.rotation % 2 ? rawHeight : rawWidth,
    height = edit.rotation % 2 ? rawWidth : rawHeight;
  const cropSize = useSize(outputSize(edit.crop, width, height));
  // A native backend measures an export's long edge on the cropped picture, as the Mac app does.
  const ofCrop = backend?.longEdgeOfCrop === true;
  const exportEdge = exportMaxEdge(exportSize, ...exportBasis(width, height, cropSize, ofCrop));
  const exportScale = Math.min(1, exportEdge / Math.max(width, height));
  const exportSourceSize = useSize(
    ofCrop
      ? exportPixels(exportEdge, width, height, cropSize, true)
      : outputSize(
          edit.crop,
          Math.max(1, Math.round(width * exportScale)),
          Math.max(1, Math.round(height * exportScale)),
        ),
  );
  const framedSize = usePrintFrame(
    edit,
    exportSourceSize.width,
    exportSourceSize.height,
    !!active &&
      !active.image.video &&
      !fixedSettings &&
      edit.printFrame !== "none",
  );
  const shownResult = result?.fileId === activeId ? result : null;
  return {
    libraryStocks,
    visibleStocks,
    rawWidth,
    rawHeight,
    width,
    height,
    cropSize,
    exportEdge,
    exportSourceSize,
    framedSize,
    shownResult,
  };
}
