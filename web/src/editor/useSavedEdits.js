import { useCallback, useEffect, useMemo, useRef } from "react";
import { loadLibraryEdit, saveLibraryEdit } from "../photo-library/index.js";
import { editStore, editText, findSavedEdit } from "../saved-edits.js";

// The photo library's records keep edits on this device unless the backend keeps them itself.
const deviceStore = { load: loadLibraryEdit, save: saveLibraryEdit };

// Every opened photograph starts from its kept edit, and every change to it is kept again
// (web/src/saved-edits.js): photo-library photos under their library key, files opened on their
// own under their identity.
export default function useSavedEdits({ backend, active, edit, stocks, setError }) {
  const store = useMemo(() => editStore(backend, deviceStore), [backend]);
  const baselines = useRef(new Map()),
    pending = useRef(null),
    timer = useRef(0);

  const savedEditFor = useCallback(
    (document) => findSavedEdit(store, stocks, document),
    [store, stocks],
  );

  const flush = useCallback(() => {
    clearTimeout(timer.current);
    const job = pending.current;
    pending.current = null;
    if (job)
      Promise.resolve()
        .then(() => store.save(job.key, job.text))
        .catch(() => setError("The edit could not be saved on this device."));
  }, [store, setError]);

  // The edit a photo opened with is its baseline: returning to an untouched
  // photo's baseline clears its saved edit rather than storing the defaults.
  const key = active?.editKey;
  useEffect(() => {
    if (pending.current && pending.current.key !== key) flush();
    if (!key) return;
    const text = editText(edit);
    const baseline = baselines.current.get(key);
    if (!baseline) {
      baselines.current.set(key, {
        text,
        saved: !!active.savedEdit,
        last: text,
      });
      return;
    }
    if (baseline.last === text) return;
    baseline.last = text;
    pending.current = {
      key,
      text: text === baseline.text && !baseline.saved ? null : text,
    };
    clearTimeout(timer.current);
    timer.current = setTimeout(flush, 400);
  }, [key, edit, flush]);
  // Keeps the edit of a photograph other than the one being edited, as a roll's change reaches
  // every frame of it (useRollActions). The photograph shown later with it keeps it as it is.
  const keepEdit = useCallback(
    (editKey, other) => {
      const text = editText(other);
      const baseline = baselines.current.get(editKey);
      if (baseline) baseline.last = text;
      return Promise.resolve().then(() => store.save(editKey, text));
    },
    [store],
  );

  useEffect(() => {
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      flush();
    };
  }, [flush]);

  return { savedEditFor, keepEdit };
}
