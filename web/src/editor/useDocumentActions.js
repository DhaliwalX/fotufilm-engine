import { useCallback } from "react";
import { VIDEO_ACCEPT } from "../media-types.js";
import { IMAGE_ACCEPT } from "../media-types.js";
import { defaultEdit, initialHistory } from "../editor-state.js";
import { newPhotoEdit } from "../app-settings.js";
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
  stocks,
  savedEditFor,
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

  // A new document starts from its kept edit (useSavedEdits), or from the settings' starting film
  // and film model (the current film unless one is chosen).
  const startingEdit = (file) =>
    file?.savedEdit ||
    newPhotoEdit(defaultEdit(edit.stock), stocks?.length ? stocks.map((s) => s.id) : null);
  // `incoming` holds Files, library items {file, editKey}, or files a native host chose
  // {path, name}, which it opens in place. Each opens with the edit kept for it; one already open
  // is shown instead of opened twice.
  async function acceptFiles(incoming) {
    if (exporting) return;
    const generation = ++loadGeneration.current;
    importController.current?.abort();
    const controller = new AbortController();
    importController.current = controller;
    const loaded = [],
      errors = [];
    let shown = null;
    for (const item of Array.from(incoming || [])) {
      const {
        file,
        path,
        name = file?.name,
        editKey = null,
      } = item instanceof Blob ? { file: item } : item;
      if (controller.signal.aborted) break;
      try {
        const options = {
          signal: controller.signal,
          onProgress: (text) => {
            if (!controller.signal.aborted) setImportStatus(`${text}: ${name}`);
          },
        };
        // A file handed over is known while it decodes; one the host opens, by its answer.
        const known = path ? null : savedEditFor({ editKey, file });
        const { identity, ...decoded } = path
          ? await backend.importPath(path, options)
          : await backend.importMedia(file, options);
        const saved = await (known ?? savedEditFor({ editKey, identity }));
        const release = () => {
          backend.releaseImage(decoded.image);
          URL.revokeObjectURL(decoded.url);
        };
        if (controller.signal.aborted) {
          release();
          break;
        }
        const open =
          saved.editKey &&
          [...files, ...loaded].find((doc) => doc.editKey === saved.editKey);
        if (open) {
          release();
          shown ??= open;
          continue;
        }
        if (saved.problem) errors.push(`${name}: ${saved.problem}`);
        loaded.push({
          id: crypto.randomUUID(),
          name,
          editKey: saved.editKey,
          savedEdit: saved.savedEdit,
          ...decoded,
        });
      } catch (e) {
        if (e.name !== "AbortError")
          errors.push(
            `${name}: ${e.message || "Could not decode image."}`,
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
    } else if (shown && files.includes(shown)) selectFile(shown);
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
