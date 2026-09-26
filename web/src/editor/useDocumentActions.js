import { useCallback } from "react";
import { VIDEO_ACCEPT } from "../media-types.js";
import { IMAGE_ACCEPT } from "../media-types.js";
import { defaultEdit, initialHistory } from "../editor-state.js";
export default function useDocumentActions({
  backend,
  exporting,
  input,
  loadGeneration,
  importController,
  setImportStatus,
  urls,
  imageResources,
  activeId,
  histories,
  history,
  setFiles,
  setActiveId,
  setVideoTime,
  dispatch,
  edit,
  replaceResult,
  setStage,
  setDifference,
  setError,
  files,
}) {
  const openFiles = useCallback(
    (kind = "all") => {
      if (exporting || !input.current) return;
      input.current.accept =
        kind === "image"
          ? IMAGE_ACCEPT
          : kind === "video"
            ? VIDEO_ACCEPT
            : `${IMAGE_ACCEPT},${VIDEO_ACCEPT}`;
      input.current.click();
    },
    [exporting, input],
  );

  // A new document starts from its library edit, or from the current film.
  const startingEdit = (file) => file?.libraryEdit || defaultEdit(edit.stock);
  // `incoming` holds Files, or library items {file, libraryKey, edit}.
  async function acceptFiles(incoming) {
    if (exporting) return;
    const generation = ++loadGeneration.current;
    importController.current?.abort();
    const controller = new AbortController();
    importController.current = controller;
    const loaded = [],
      errors = [];
    for (const item of Array.from(incoming || [])) {
      const {
        file,
        libraryKey = null,
        edit: libraryEdit = null,
      } = item instanceof Blob ? { file: item } : item;
      if (controller.signal.aborted) break;
      try {
        const decoded = await backend.importMedia(file, {
          signal: controller.signal,
          onProgress: (text) => {
            if (!controller.signal.aborted)
              setImportStatus(`${text}: ${file.name}`);
          },
        });
        if (controller.signal.aborted) {
          backend.releaseImage(decoded.image);
          URL.revokeObjectURL(decoded.url);
          break;
        }
        loaded.push({
          id: crypto.randomUUID(),
          name: file.name,
          libraryKey,
          libraryEdit,
          ...decoded,
        });
      } catch (e) {
        if (e.name !== "AbortError")
          errors.push(
            `${file.name}: ${e.message || "Could not decode image."}`,
          );
      }
    }
    if (generation !== loadGeneration.current) {
      loaded.forEach((file) => {
        backend.releaseImage(file.image);
        URL.revokeObjectURL(file.url);
      });
      return;
    }
    setImportStatus(null);
    importController.current = null;
    if (loaded.length) {
      loaded.forEach((file) => {
        urls.current.add(file.url);
        imageResources.current.add(file.image);
      });
      if (activeId) histories.current.set(activeId, history);
      setFiles((current) => [...current, ...loaded]);
      setActiveId(loaded[0].id);
      setVideoTime(loaded[0].image.video?.start || 0);
      dispatch({
        type: "load",
        edit: startingEdit(loaded[0]),
      });
      replaceResult(null);
      setStage(null);
      setDifference(false);
    }
    setError(errors.length ? errors.join(" ") : null);
  }
  function selectFile(file) {
    if (file.id === activeId || exporting) return;
    histories.current.set(activeId, history);
    setActiveId(file.id);
    setVideoTime(file.image.video?.start || 0);
    dispatch({
      type: "restore",
      history: histories.current.get(file.id) || {
        ...initialHistory,
        present: startingEdit(file),
      },
    });
    replaceResult(null);
    setStage(null);
    setDifference(false);
  }
  function removeFile(file) {
    if (exporting) return;
    const remaining = files.filter((item) => item.id !== file.id);
    if (file.id === activeId) {
      const next = remaining[Math.max(0, files.indexOf(file) - 1)];
      setActiveId(next?.id || null);
      setVideoTime(next?.image.video?.start || 0);
      dispatch({
        type: "restore",
        history: histories.current.get(next?.id) || {
          ...initialHistory,
          present: startingEdit(next),
        },
      });
      replaceResult(null);
    }
    backend.releaseImage(file.image);
    imageResources.current.delete(file.image);
    histories.current.delete(file.id);
    setFiles(remaining);
    URL.revokeObjectURL(file.url);
    urls.current.delete(file.url);
  }
  return {
    openFiles,
    acceptFiles,
    selectFile,
    removeFile,
  };
}
