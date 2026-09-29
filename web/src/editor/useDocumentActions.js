import { useCallback, useRef } from "react";
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
      if (exporting) return;
      // A native host's own open panel, whose files arrive as its File › Open's do and are
      // kept in Open Recent.
      if (backend.openPanel) {
        backend.openPanel(kind).catch(console.error);
        return;
      }
      if (!input.current) return;
      input.current.accept =
        kind === "image"
          ? IMAGE_ACCEPT
          : kind === "video"
            ? VIDEO_ACCEPT
            : `${IMAGE_ACCEPT},${VIDEO_ACCEPT}`;
      input.current.click();
    },
    [backend, exporting, input],
  );

  // A new document starts from its kept edit (useSavedEdits), or from the settings' starting film
  // and film model (the current film unless one is chosen).
  const startingEdit = (file) =>
    file?.savedEdit ||
    newPhotoEdit(defaultEdit(edit.stock), stocks?.length ? stocks.map((s) => s.id) : null);
  // Each document's edit as it stands: the one being edited, one edited before as it was left,
  // and one not opened yet as it would open, with the edit kept for its file (Export All).
  async function documentEdits(docs) {
    const unopened = docs.filter((doc) => doc.waiting && !doc.editKey && sourcePath(doc));
    const identities =
      unopened.length && backend.fileIdentities
        ? await backend.fileIdentities(unopened.map(sourcePath)).catch(() => [])
        : [];
    const identity = new Map(unopened.map((doc, i) => [doc.id, identities[i] ?? null]));
    return Promise.all(
      docs.map(async (doc) => {
        if (doc.id === activeId) return edit;
        if (!doc.waiting)
          return histories.current.get(doc.id)?.present ?? startingEdit(doc);
        const { savedEdit } = await savedEditFor({
          editKey: doc.editKey,
          identity: identity.get(doc.id),
          file: identity.has(doc.id) ? undefined : doc.source.file,
        });
        return startingEdit({ savedEdit });
      }),
    );
  }
  // The newest actions and documents, for a decode that finishes after the editor has moved on.
  const latest = useRef(null),
    // The waiting photograph being decoded because it was chosen.
    activation = useRef(null);
  const release = (decoded) => {
    backend.releaseImage(decoded.image);
    URL.revokeObjectURL(decoded.url);
  };
  // Decodes a file for editing, and finds the edit kept for it: a file handed over is known while
  // it decodes, one the host opens by its answer.
  async function decode({ file, path, name, editKey = null }, signal) {
    const options = {
      signal,
      onProgress: (text) => {
        if (!signal.aborted) setImportStatus(`${text}: ${name}`);
      },
    };
    const known = path ? null : savedEditFor({ editKey, file });
    const { identity, ...decoded } = path
      ? await backend.importPath(path, options)
      : await backend.importMedia(file, options);
    return {
      decoded,
      saved: await (known ?? savedEditFor({ editKey, identity })),
    };
  }
  // Whether an open document came from this file: the same path, library photo or File.
  const opensFrom = (doc, item) =>
    (item.path && doc.source?.path === item.path) ||
    (item.editKey && doc.editKey === item.editKey) ||
    (item.file && doc.source?.file === item.file);

  // `incoming` holds Files, library items {file, editKey}, or files a native host chose
  // {path, name}, which it opens in place. Each opens with the edit kept for it; one already open
  // is shown instead of opened twice. Only the first new photograph is decoded: the others wait
  // in the strip, as thumbnails, until they are chosen.
  async function acceptFiles(incoming) {
    if (exporting) return;
    const generation = ++loadGeneration.current;
    importController.current?.abort();
    const controller = new AbortController();
    importController.current = controller;
    const loaded = [],
      waiting = [],
      errors = [];
    let shown = null;
    for (const entry of Array.from(incoming || [])) {
      const { file, path, name = file?.name, editKey = null } =
        entry instanceof Blob ? { file: entry } : entry;
      const item = { file, path, name, editKey };
      if (controller.signal.aborted) break;
      const already = [...files, ...loaded, ...waiting].find((doc) =>
        opensFrom(doc, item),
      );
      if (already) {
        shown ??= already;
        continue;
      }
      if (loaded.length) {
        waiting.push({
          id: crypto.randomUUID(),
          name,
          editKey,
          source: item,
          waiting: true,
          url: null,
        });
        continue;
      }
      try {
        const { decoded, saved } = await decode(item, controller.signal);
        if (controller.signal.aborted) {
          release(decoded);
          break;
        }
        const open =
          saved.editKey &&
          [...files, ...loaded].find((doc) => doc.editKey === saved.editKey);
        if (open) {
          release(decoded);
          shown ??= open;
          continue;
        }
        if (saved.problem) errors.push(`${name}: ${saved.problem}`);
        loaded.push({
          id: crypto.randomUUID(),
          name,
          editKey: saved.editKey,
          savedEdit: saved.savedEdit,
          source: item,
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
      loaded.forEach(release);
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
      setFiles((current) => [...current, ...loaded, ...waiting]);
      setActiveId(loaded[0].id);
      setVideoTime(loaded[0].image.video?.start || 0);
      dispatch({
        type: "load",
        edit: startingEdit(loaded[0]),
      });
      replaceResult(null);
      setStage(null);
      setDifference(false);
      drawThumbnails(waiting);
    } else if (shown && files.includes(shown)) selectFile(shown);
    setError(errors.length ? errors.join(" ") : null);
  }
  // The waiting photographs' pictures, one at a time once the first photograph's preview is
  // queued. A backend that cannot draw one leaves its name showing.
  async function drawThumbnails(waiting) {
    if (!backend.thumbnail || !waiting.length) return;
    await new Promise((resolve) => setTimeout(resolve, 400));
    for (const doc of waiting) {
      const url = await backend
        .thumbnail(doc.source, { maxEdge: 256 })
        .catch(() => null);
      if (!url) continue;
      if (!latest.current.files.some((item) => item.id === doc.id && item.waiting)) {
        URL.revokeObjectURL(url);
        continue;
      }
      urls.current.add(url);
      setFiles((current) =>
        current.map((item) => (item.id === doc.id ? { ...item, url } : item)),
      );
    }
  }
  // A waiting photograph is decoded when it is chosen and takes its place in the strip. Choosing
  // another photograph meanwhile abandons it.
  async function openWaiting(file) {
    activation.current?.abort();
    const controller = new AbortController();
    activation.current = controller;
    let opened;
    try {
      opened = await decode(file.source, controller.signal);
    } catch (e) {
      if (activation.current !== controller) return;
      activation.current = null;
      setImportStatus(null);
      if (e.name !== "AbortError")
        setError(`${file.name}: ${e.message || "Could not decode image."}`);
      return;
    }
    const { decoded, saved } = opened;
    const now = latest.current;
    if (controller.signal.aborted) {
      release(decoded);
      return;
    }
    activation.current = null;
    setImportStatus(null);
    // Closed while it decoded.
    if (!now.files.some((doc) => doc.id === file.id)) {
      release(decoded);
      return;
    }
    const open =
      saved.editKey && now.files.find((doc) => doc.editKey === saved.editKey && !doc.waiting);
    if (open) {
      release(decoded);
      now.removeFile(file);
      now.selectFile(open);
      return;
    }
    setError(saved.problem ? `${file.name}: ${saved.problem}` : null);
    const ready = {
      id: file.id,
      name: file.name,
      editKey: saved.editKey,
      savedEdit: saved.savedEdit,
      source: file.source,
      ...decoded,
    };
    urls.current.add(ready.url);
    imageResources.current.add(ready.image);
    if (file.url) {
      URL.revokeObjectURL(file.url);
      urls.current.delete(file.url);
    }
    setFiles((current) => current.map((doc) => (doc.id === file.id ? ready : doc)));
    now.selectFile(ready);
  }
  function selectFile(file) {
    if (file.id === activeId || exporting) return;
    if (file.waiting) {
      openWaiting(file);
      return;
    }
    if (activation.current) {
      activation.current.abort();
      activation.current = null;
      setImportStatus(null);
    }
    if (activeId) histories.current.set(activeId, history);
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
    let next = null;
    if (file.id === activeId) {
      next = remaining[Math.max(0, files.indexOf(file) - 1)] || null;
      // A waiting neighbour is shown once it has decoded.
      const shownNext = next?.waiting ? null : next;
      setActiveId(shownNext?.id || null);
      setVideoTime(shownNext?.image.video?.start || 0);
      dispatch({
        type: "restore",
        history: histories.current.get(shownNext?.id) || {
          ...initialHistory,
          present: startingEdit(shownNext),
        },
      });
      replaceResult(null);
    }
    if (file.image) {
      backend.releaseImage(file.image);
      imageResources.current.delete(file.image);
    }
    histories.current.delete(file.id);
    setFiles(remaining);
    if (file.url) {
      URL.revokeObjectURL(file.url);
      urls.current.delete(file.url);
    }
    if (next?.waiting) openWaiting(next);
  }
  latest.current = { files, selectFile, removeFile };
  return {
    openFiles,
    acceptFiles,
    selectFile,
    removeFile,
    documentEdits,
  };
}

// Where the host can read a document's file itself: a file it opened, or a library photograph in
// a folder it serves.
export const sourcePath = (doc) => doc.source?.path ?? doc.source?.file?.hostPath ?? null;
