import { useCallback, useEffect, useRef, useState } from "react";
import { parseEdit } from "../editor-state.js";
import { validateStockSettings } from "../stock-settings.js";
import { saveLibraryEdit } from "../photo-library/index.js";

const editText = (edit) => JSON.stringify({ version: 1, edit });

// Connects the photo library to the editor: opened photos start from their saved
// edit, and every change to a library photo is saved back to it.
export default function useLibraryDocuments({
  files,
  active,
  edit,
  stocks,
  exporting,
  acceptFiles,
  selectFile,
  setError,
  setLibraryOpen,
}) {
  const [handoff, setHandoff] = useState(null);
  const baselines = useRef(new Map()),
    pending = useRef(null),
    timer = useRef(0);

  const openFromLibrary = useCallback(
    async ({ items, missing, origin }) => {
      if (exporting || (!items.length && !missing.length)) return;
      setLibraryOpen(false);
      const problems = missing.map(
        (name) => `${name} is no longer in its folder.`,
      );
      const open = new Map(
        files
          .filter((file) => file.libraryKey)
          .map((file) => [file.libraryKey, file]),
      );
      const fresh = [];
      for (const item of items) {
        if (open.has(item.key)) continue;
        let restored = null;
        if (item.edit)
          try {
            restored = parseEdit(
              item.edit,
              stocks.map((stock) => stock.id),
            );
            validateStockSettings(
              restored,
              stocks.find((stock) => stock.id === restored.stock),
            );
          } catch (error) {
            restored = null;
            problems.push(
              `${item.name}: the saved edit was not restored. ${error.message}`,
            );
          }
        fresh.push({ file: item.file, libraryKey: item.key, edit: restored });
      }
      if (origin && items[0]) setHandoff({ ...origin, key: items[0].key });
      if (fresh.length) await acceptFiles(fresh);
      else if (open.has(items[0]?.key)) selectFile(open.get(items[0].key));
      if (problems.length)
        setError((current) => [current, ...problems].filter(Boolean).join(" "));
    },
    [
      exporting,
      files,
      stocks,
      acceptFiles,
      selectFile,
      setError,
      setLibraryOpen,
    ],
  );

  const flush = useCallback(() => {
    clearTimeout(timer.current);
    const job = pending.current;
    pending.current = null;
    if (job)
      saveLibraryEdit(job.key, job.text).catch(() =>
        setError("This browser could not save the edit to the library."),
      );
  }, [setError]);

  // The edit a photo opened with is its baseline: returning to an untouched
  // photo's baseline clears its saved edit rather than storing the defaults.
  const key = active?.libraryKey;
  useEffect(() => {
    if (pending.current && pending.current.key !== key) flush();
    if (!key) return;
    const text = editText(edit);
    const baseline = baselines.current.get(key);
    if (!baseline) {
      baselines.current.set(key, {
        text,
        saved: !!active.libraryEdit,
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
  useEffect(() => {
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      flush();
    };
  }, [flush]);

  return {
    openFromLibrary,
    libraryHandoff: handoff,
    endLibraryHandoff: useCallback(() => setHandoff(null), []),
  };
}
