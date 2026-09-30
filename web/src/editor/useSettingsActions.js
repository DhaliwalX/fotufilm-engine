import {
  copySettings,
  deletePreset,
  pasteSettings,
  savePreset,
  setCopiedSettings,
  useEditSettings,
} from "../edit-settings.js";
import { editText, restoreEdit } from "../saved-edits.js";

// Copy Settings, Paste Settings and presets, shared by the options menu and the native menu bar.
export default function useSettingsActions({
  edit,
  stocks,
  dispatch,
  setStage,
  setDifference,
  setError,
  setDialog,
}) {
  const editSettings = useEditSettings();

  // Pasted as a whole edit, through the same checks a kept edit is opened with.
  function apply(settings) {
    try {
      const pasted = pasteSettings(edit, settings);
      // A new film keeps a chosen medium only where it offers one, as choosing the film does.
      if (
        pasted.stock !== edit.stock &&
        !settings.sections.includes("printPaper")
      ) {
        const stock = stocks.find(({ id }) => id === pasted.stock);
        if (pasted.mediumFollowsFilm) pasted.medium = stock?.filmMedium ?? null;
        else if (!stock?.media.some(({ id }) => id === pasted.medium))
          pasted.medium = null;
      }
      dispatch({
        type: "edit",
        patch: restoreEdit(editText(pasted), stocks),
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
    editSettings,
    copySettings: (sections) => {
      setCopiedSettings(copySettings(edit, sections));
      setDialog(null);
    },
    pasteSettings: () => editSettings.copied && apply(editSettings.copied),
    applyPreset: (id) => {
      const preset = editSettings.presets.find((p) => p.id === id);
      if (preset) apply(preset.settings);
    },
    savePreset: (name, sections) => {
      savePreset(name, copySettings(edit, sections));
      setDialog(null);
    },
    deletePreset,
  };
}
