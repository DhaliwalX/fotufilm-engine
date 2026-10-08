import { useCallback, useRef } from "react";
import { IMAGE_ACCEPT, NEGATIVE_ACCEPT, VIDEO_ACCEPT } from "../media-types.js";
import { defaultEdit, initialHistory } from "../editor-state.js";
import { newPhotoEdit } from "../app-settings.js";
import { negativeStartingStock, newNegative } from "../negative-document.js";
import { copySettings, pastedEdit } from "../edit-settings.js";
import { restoreEdit } from "../saved-edits.js";
// What a trichromatic merge left out, in a sentence each: frames it could not merge, blank
// exposures and exposures under white light.
export function trichromaticNotes({ failures = [], blanks = [], others = [], repeats = [], loose = [] }) {
  const list = (names) => names.join(", ");
  return [
    ...failures.map(({ sources, reason }) => `${list(sources)}: ${reason}`),
    blanks.length ? `Left out as blank: ${list(blanks)}.` : "",
    others.length ? `Left out, not under one light: ${list(others)}.` : "",
    repeats.length ? `Left out, repeated by the next exposure: ${list(repeats)}.` : "",
    loose.length ? `Lined up loosely, so colours may fringe: ${list(loose)}.` : "",
  ]
    .filter(Boolean)
    .join(" ");
}

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
      input.current.dataset.negative = "";
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
  // Scanned negatives open as documents, where the backend reads them as a film.
  const chooseNegatives = useCallback(() => {
    if (exporting || !input.current) return;
    input.current.dataset.negative = "true";
    input.current.accept = NEGATIVE_ACCEPT;
    input.current.click();
  }, [exporting, input]);
  const importNegatives = backend.negativeScans ? chooseNegatives : null;
  // Trichromatic scans: exposures of negatives under red, green and blue light, merged into scans
  // (backend.negativeScans.mergeTrichromatic) that open as negatives. A host with its own open
  // panel asks for the exposures; otherwise they are chosen here.
  const trichromatic = backend.negativeScans?.mergeTrichromatic;
  const chooseExposures = () => {
    if (exporting) return;
    if (backend.negativeScans.choosesExposures) {
      mergeExposures();
      return;
    }
    if (!input.current) return;
    input.current.dataset.negative = "trichromatic";
    input.current.accept = NEGATIVE_ACCEPT;
    input.current.click();
  };
  const importTrichromatic = trichromatic ? chooseExposures : null;
  async function mergeExposures(chosen) {
    if (exporting) return;
    importController.current?.abort();
    const controller = new AbortController();
    importController.current = controller;
    setImportStatus("Merging exposures");
    let merged;
    try {
      merged = await trichromatic(chosen, {
        signal: controller.signal,
        onProgress: (progress) => {
          if (controller.signal.aborted || !progress?.status) return;
          setImportStatus(`${progress.status} · ${Math.round(100 * (progress.progress ?? 0))}%`);
        },
      });
    } catch (e) {
      if (importController.current === controller) {
        importController.current = null;
        setImportStatus(null);
      }
      if (e.name !== "AbortError") setError(e.message || "The exposures could not be merged.");
      return;
    }
    if (importController.current !== controller) return;
    importController.current = null;
    setImportStatus(null);
    const left = trichromaticNotes(merged);
    if (merged.scans.length)
      await acceptFiles(merged.scans.map(({ file, path, name }) => ({ file, path, name, negative: true })));
    if (left) setError(left);
  }

  // A new document starts from its kept edit (useSavedEdits), or from the settings' starting film
  // and film model (the current film unless one is chosen).
  // A negative opens on the film its base looks like, read against an estimated base; one kept
  // as a photograph opens as a negative afresh. A new frame of a roll (a library folder of
  // negatives) starts as the frame edited last reads it: its film, the film's settings, its
  // clear film and its light source, as pasting the Film section carries them.
  const startingEdit = (file) => {
    if (file?.image?.negative || file?.source?.negative) {
      if (file.savedEdit?.negative) return file.savedEdit;
      const start = {
        ...defaultEdit(negativeStartingStock(file.image, stocks ?? [], edit.stock)),
        negative: newNegative(),
      };
      const roll = rollEdit(file.source?.roll);
      return roll ? pastedEdit(start, copySettings(roll, ["filmStock"]), stocks) : start;
    }
    return (
      file?.savedEdit ||
      newPhotoEdit(defaultEdit(edit.stock), stocks?.length ? stocks.map((s) => s.id) : null)
    );
  };
  // A roll's kept edit, when it still reads with the films installed.
  const rollEdit = (text) => {
    if (!text || !stocks?.length) return null;
    try {
      const kept = restoreEdit(text, stocks);
      return kept.negative ? kept : null;
    } catch {
      return null;
    }
  };
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
        return startingEdit({ savedEdit, source: doc.source });
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
  // A negative is decoded as a scan: one chosen as a negative, or one whose kept edit reads it.
  async function decode({ file, path, name, editKey = null, negative = false }, signal) {
    const options = {
      signal,
      negative: negative && !!backend.negativeScans,
      onProgress: (text) => {
        if (!signal.aborted) setImportStatus(`${text}: ${name}`);
      },
    };
    const open = () =>
      path ? backend.importPath(path, options) : backend.importMedia(file, options);
    const known = path ? null : savedEditFor({ editKey, file });
    let { identity, ...decoded } = await open();
    const saved = await (known ?? savedEditFor({ editKey, identity }));
    if (saved.savedEdit?.negative && !decoded.image.negative && backend.negativeScans) {
      release(decoded);
      options.negative = true;
      ({ identity, ...decoded } = await open());
    }
    return { decoded, saved };
  }
  // Whether an open document came from this file: the same path, library photo or File.
  const opensFrom = (doc, item) =>
    (item.path && doc.source?.path === item.path) ||
    (item.editKey && doc.editKey === item.editKey) ||
    (item.file && doc.source?.file === item.file);

  // `incoming` holds Files, library items {file, editKey}, or files a native host chose
  // {path, name}, which it opens in place. Each opens with the edit kept for it; one already open
  // is shown instead of opened twice. Only one new photograph is decoded, the one marked `shown`
  // (a library photo opened with its roll) or else the first: the others wait in the strip, as
  // thumbnails, until they are chosen. The strip takes them in the order they came.
  async function acceptFiles(incoming) {
    if (exporting) return;
    const generation = ++loadGeneration.current;
    importController.current?.abort();
    const controller = new AbortController();
    importController.current = controller;
    const entries = Array.from(incoming || [], (entry, order) => {
      const {
        file,
        path,
        name = file?.name,
        editKey = null,
        negative = false,
        roll = null,
        shown = false,
      } = entry instanceof Blob ? { file: entry } : entry;
      return { item: { file, path, name, editKey, negative, roll }, order, shown };
    });
    const first = Math.max(0, entries.findIndex((entry) => entry.shown));
    const loaded = [],
      waiting = [],
      errors = [];
    let shown = null;
    for (const { item, order } of [...entries.slice(first, first + 1),
      ...entries.slice(0, first), ...entries.slice(first + 1)]) {
      const { name, editKey } = item;
      if (controller.signal.aborted) break;
      const already = [...files, ...loaded, ...waiting].find((doc) =>
        opensFrom(doc, item),
      );
      if (already) {
        shown ??= already;
        continue;
      }
      if (loaded.length || shown) {
        waiting.push({
          id: crypto.randomUUID(),
          name,
          editKey,
          source: item,
          waiting: true,
          url: null,
          order,
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
          order,
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
    const added = [...loaded, ...waiting]
      .sort((a, b) => a.order - b.order)
      .map(({ order: _order, ...doc }) => doc);
    if (loaded.length) {
      loaded.forEach((file) => {
        urls.current.add(file.url);
        imageResources.current.add(file.image);
      });
      if (activeId) histories.current.set(activeId, history);
      setFiles((current) => [...current, ...added]);
      setActiveId(loaded[0].id);
      setVideoTime(loaded[0].image.video?.start || 0);
      dispatch({
        type: "load",
        edit: startingEdit(loaded[0]),
      });
      replaceResult(null);
      setStage(null);
      setDifference(false);
      drawThumbnails(added.filter((doc) => doc.waiting));
    } else if (shown && files.includes(shown)) {
      // The photo chosen is open already: the rest of its roll joins the strip around it.
      if (added.length) {
        setFiles((current) => [...current, ...added]);
        drawThumbnails(added);
      }
      selectFile(shown);
    }
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
  // Closes photos; when the shown one closes, the nearest one before it that stays is shown.
  function removeFiles(closing) {
    if (exporting) return;
    const ids = new Set(closing.map((file) => file.id));
    const remaining = files.filter((item) => !ids.has(item.id));
    let next = null;
    if (ids.has(activeId)) {
      const shown = files.findIndex((item) => item.id === activeId);
      next =
        files.slice(0, shown).findLast((item) => !ids.has(item.id)) || remaining[0] || null;
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
    for (const file of files.filter((item) => ids.has(item.id))) {
      if (file.image) {
        backend.releaseImage(file.image);
        imageResources.current.delete(file.image);
      }
      histories.current.delete(file.id);
      if (file.url) {
        URL.revokeObjectURL(file.url);
        urls.current.delete(file.url);
      }
    }
    setFiles(remaining);
    if (next?.waiting) openWaiting(next);
  }
  const removeFile = (file) => removeFiles([file]);
  latest.current = { files, selectFile, removeFile };
  return {
    openFiles,
    importNegatives,
    importTrichromatic,
    mergeExposures,
    acceptFiles,
    selectFile,
    removeFile,
    removeFiles,
    documentEdits,
  };
}

// Where the host can read a document's file itself: a file it opened, or a library photograph in
// a folder it serves.
export const sourcePath = (doc) => doc.source?.path ?? doc.source?.file?.hostPath ?? null;
