import {
  fixedStockSettings,
  selectStockSettings,
  validateStockSettings,
} from "../stock-settings.js";
import { download } from "./file-download.js";
import { cleanName } from "./file-download.js";
import { parseEdit } from "../editor-state.js";
export default function useFilmActions({
  exporting,
  stocks,
  auto,
  edit,
  patch,
  setStage,
  setDifference,
  active,
  setDialog,
  dispatch,
  setError,
}) {
  function selectStock(id) {
    if (exporting) return;
    const nextStock = stocks.find((stock) => stock.id === id);
    if (fixedStockSettings(nextStock) && auto.active) auto.toggle();
    const medium = stocks
      .find((s) => s.id === id)
      ?.media.some((m) => m.id === edit.medium)
      ? edit.medium
      : null;
    const halationModel =
      stocks.find((s) => s.id === id)?.layeredTransport === false
        ? "legacy"
        : edit.halationModel || "legacy";
    patch({
      stock: id,
      ...selectStockSettings(nextStock),
      medium: halationModel === "layered" ? null : medium,
      halationModel,
    });
    setStage(null);
    setDifference(false);
  }
  function saveEdit() {
    download(
      new Blob(
        [
          JSON.stringify(
            {
              version: 1,
              edit,
            },
            null,
            2,
          ),
        ],
        {
          type: "application/json",
        },
      ),
      `${cleanName(active?.name || "photo")}.fotufilm-web.json`,
    );
    setDialog(null);
  }
  async function restoreEdit(file) {
    if (!file) return;
    try {
      const restored = parseEdit(
        await file.text(),
        stocks.map((s) => s.id),
      );
      validateStockSettings(
        restored,
        stocks.find((stock) => stock.id === restored.stock),
      );
      dispatch({
        type: "edit",
        patch: restored,
        restoring: true,
      });
      setStage(null);
      setDifference(false);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }
  return {
    selectStock,
    saveEdit,
    restoreEdit,
  };
}
