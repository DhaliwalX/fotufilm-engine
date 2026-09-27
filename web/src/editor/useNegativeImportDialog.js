import { useEditor } from "./EditorContext.jsx";
import { useBackend } from "../backend/BackendContext.jsx";
import { defaultEdit } from "../editor-state.js";
import { negativeEdit } from "../negative-live-preview.js";
import useNegativeImport from "../useNegativeImport.js";
import { useNegativeScanSession } from "../negative-scan/useNegativeScanSession.js";

// The negative dialog's owner. A backend that prints negative scans itself (`negativeScans`)
// gets the session the apps have; any other keeps the automatic import.
export function useNegativeImportDialog() {
  const {
    dialog,
    setDialog,
    urls,
    imageResources,
    activeId,
    histories,
    history,
    setFiles,
    setActiveId,
    dispatch,
    replaceResult,
    setStage,
    setDifference,
    setVideoTime,
    setInspector,
    session,
  } = useEditor();
  const scans = useBackend().negativeScans ?? null;
  const open = dialog === "negative";
  function openPositive(file, edit, inspector) {
    urls.current.add(file.url);
    imageResources.current.add(file.image);
    if (activeId) histories.current.set(activeId, history);
    setFiles((current) => [...current, file]);
    setActiveId(file.id);
    dispatch({ type: "load", edit });
    replaceResult(null);
    setStage(null);
    setDifference(false);
    setVideoTime(0);
    setDialog(null);
    if (inspector) setInspector(inspector);
  }
  const legacy = useNegativeImport(
    (file, settings) => openPositive(file, negativeEdit(settings), "crop"),
    open && !scans,
    session,
  );
  const scan = useNegativeScanSession(scans, open && !!scans);
  return {
    ...legacy,
    scans,
    scan,
    // The session's positive is the finished print, framed and toned: it opens with no film.
    importScan: (committed) =>
      openPositive(
        {
          ...committed,
          name: `${scan.file?.name ?? "Negative"} — Positive`,
          id: crypto.randomUUID(),
        },
        defaultEdit(null),
      ),
  };
}
