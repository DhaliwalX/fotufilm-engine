import {
  copySettings,
  deletePreset,
  pastedEdit,
  savePreset,
  setCopiedSettings,
  useEditSettings,
} from "../edit-settings.js";

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

  function apply(settings) {
    try {
      dispatch({
        type: "edit",
        patch: pastedEdit(edit, settings, stocks),
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
