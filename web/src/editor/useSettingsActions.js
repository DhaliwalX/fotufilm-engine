import { useRef } from "react";
import {
  copySettings,
  deletePreset,
  importPresets,
  pastedEdit,
  savePreset,
  setCopiedSettings,
  useEditSettings,
} from "../edit-settings.js";
import {
  LOOK_TYPE,
  isLookFile,
  lookFileName,
  lookText,
  readLooks,
} from "../look-files.js";
import { download } from "./file-download.js";

const HISTORY_LIMIT = 100;

// Copy Settings, Paste Settings and presets, shared by the options menu and the native menu bar.
// A paste or preset goes onto every photo chosen in the strip: the one shown as one step Undo
// reverses, each of the others as a step of its own history, kept as its edit is.
export default function useSettingsActions(editor) {
  const {
    edit,
    stocks,
    dispatch,
    setStage,
    setDifference,
    setError,
    setDialog,
    selectedFiles,
    acceptFiles,
    backend,
  } = editor;
  const editSettings = useEditSettings();
  const latest = useRef(editor);
  latest.current = editor;
  const applying = useRef(false);

  function applyShown(settings) {
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

  async function applyChosen(settings, docs) {
    if (applying.current) return;
    applying.current = true;
    try {
      const states = await latest.current.documentStates(docs);
      const now = latest.current;
      const failed = [],
        saves = [];
      docs.forEach((doc, index) => {
        if (!now.files.some(({ id }) => id === doc.id)) return;
        const shown = doc.id === now.activeId;
        const before = shown ? now.edit : states[index].edit;
        let after;
        try {
          after = pastedEdit(before, settings, now.stocks);
        } catch (e) {
          failed.push(`${doc.name}: ${e.message}`);
          return;
        }
        if (shown) {
          now.dispatch({ type: "edit", patch: after, restoring: true });
          return;
        }
        const key = states[index].editKey;
        // A photo not opened yet holds its edit only where it is kept.
        if (doc.waiting && !key) {
          failed.push(`${doc.name}: its edit cannot be kept on this device.`);
          return;
        }
        const history = now.histories.current.get(doc.id);
        now.histories.current.set(doc.id, {
          past: [...(history?.past ?? []), history?.present ?? before].slice(
            -HISTORY_LIMIT,
          ),
          present: after,
          future: [],
          group: null,
        });
        if (key)
          saves.push(
            now.keepEdit(key, after).catch(() => {
              failed.push(
                `${doc.name}: the edit could not be saved on this device.`,
              );
            }),
          );
      });
      await Promise.all(saves);
      now.setStage(null);
      now.setDifference(false);
      now.setError(
        failed.length
          ? `Applied to ${docs.length - failed.length} of ${docs.length} photos. ${failed.join(" ")}`
          : null,
      );
    } catch (e) {
      latest.current.setError(
        e.message || "The settings could not be applied.",
      );
    } finally {
      applying.current = false;
    }
  }

  function apply(settings) {
    if (selectedFiles.length > 1) applyChosen(settings, selectedFiles);
    else applyShown(settings);
  }

  // A look file is saved where the host asks, or downloaded in a browser.
  async function exportPresets(ids) {
    const chosen = editSettings.presets.filter((p) => ids.includes(p.id));
    if (!chosen.length) return;
    const name = lookFileName(chosen),
      text = lookText(chosen);
    try {
      if (backend.saveFile)
        await backend.saveFile({ filename: name, type: LOOK_TYPE, text });
      else download(new Blob([text], { type: LOOK_TYPE }), name);
    } catch (e) {
      if (e.name !== "AbortError")
        setError(e.message || "The look could not be saved.");
    }
  }

  async function importLooks(files) {
    const notes = [];
    let added = 0;
    for (const file of files) {
      try {
        const { presets, missing } = readLooks(await file.text(), stocks);
        added += importPresets(presets);
        for (const { name, film } of missing)
          notes.push(
            `“${name}” uses ${film}, which is not installed; it applies once the film is.`,
          );
      } catch (e) {
        notes.push(`${file.name}: ${e.message}`);
      }
    }
    setError(notes.length ? notes.join(" ") : null);
    if (added && !notes.length) setDialog("presets");
    return added;
  }

  // Look files dropped or chosen with photographs are added as presets; the rest open.
  function acceptWithLooks(incoming) {
    const items = Array.from(incoming || []);
    const looks = items.filter(
      (item) => item instanceof Blob && isLookFile(item.name),
    );
    const others = items.filter((item) => !looks.includes(item));
    if (looks.length) importLooks(looks);
    if (others.length || !looks.length) return acceptFiles(others);
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
    exportPresets,
    importLooks,
    acceptFiles: acceptWithLooks,
  };
}
