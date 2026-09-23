import { useEditor } from "./EditorContext.jsx";
import { defaultEdit } from "../editor-state.js";
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
  } = useEditor();
  return useNegativeImport((file) => {
    urls.current.add(file.url);
    imageResources.current.add(file.image);
    if (activeId) histories.current.set(activeId, history);
    setFiles((current) => [...current, file]);
    setActiveId(file.id);
    dispatch({ type: "load", edit: defaultEdit(null) });
    replaceResult(null);
    setStage(null);
    setDifference(false);
    setVideoTime(0);
    setDialog(null);
    setInspector("crop");
  }, dialog === "negative");
}
