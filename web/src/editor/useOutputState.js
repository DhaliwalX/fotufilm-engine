import { outputSize } from "../geometry.js";
import { usePrintFrame } from "../usePrintFrame.js";
export default function useOutputState({
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
  const visibleStocks = stocks.filter((stock) =>
    stock.name.toLowerCase().includes(search.toLowerCase()),
  );
  const rawWidth = active?.image.naturalWidth || 0,
    rawHeight = active?.image.naturalHeight || 0;
  const width = edit.rotation % 2 ? rawHeight : rawWidth,
    height = edit.rotation % 2 ? rawWidth : rawHeight;
  const cropSize = outputSize(edit.crop, width, height);
  const exportScale =
    exportSize === "full"
      ? 1
      : Math.min(1, Number(exportSize) / Math.max(width, height));
  const exportSourceSize = outputSize(
    edit.crop,
    Math.max(1, Math.round(width * exportScale)),
    Math.max(1, Math.round(height * exportScale)),
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
    visibleStocks,
    rawWidth,
    rawHeight,
    width,
    height,
    cropSize,
    exportScale,
    exportSourceSize,
    framedSize,
    shownResult,
  };
}
