import { useEditor } from "./EditorContext.jsx";
import { negativeEdit } from "../negative-live-preview.js";
import useNegativeImport from "../useNegativeImport.js";

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
  return useNegativeImport(
    (file, settings) => {
      urls.current.add(file.url);
      imageResources.current.add(file.image);
      if (activeId) histories.current.set(activeId, history);
      setFiles((current) => [...current, file]);
      setActiveId(file.id);
      dispatch({ type: "load", edit: negativeEdit(settings) });
      replaceResult(null);
      setStage(null);
      setDifference(false);
      setVideoTime(0);
      setDialog(null);
      setInspector("crop");
    },
    dialog === "negative",
    session,
  );
}
