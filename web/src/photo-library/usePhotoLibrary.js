import { useCallback, useEffect, useRef, useState } from "react";
import {
  forgetFolder,
  forgetPhotos,
  loadFolders,
  loadIndex,
  loadPhotoRecords,
  movePhoto,
  onRecordChange,
  saveFolder,
  saveIndex,
  updatePhotoRecords,
} from "./library-store.js";
import {
  indexRows,
  indexedPhotos,
  photoEntry,
  scanDirectory,
  uploadedFolders,
} from "./library-scan.js";
import { folderAccess } from "./folder-access.js";

export const supportsFolderAccess = () => folderAccess().persistent();

// A folder of scanned negatives (`negative`) opens its photos as negatives.
const stored = ({ id, name, handle, added, negative = false }) => ({
  id,
  name,
  handle,
  added,
  negative,
});
const message = (error, fallback) =>
  error?.name === "NotFoundError"
    ? "This folder has moved or been deleted."
    : error?.message || fallback;

// A refreshed folder keeps the objects of unchanged photos, and the same list
// when nothing changed, so a refresh redraws only what it must.
function keepUnchanged(previous, photos) {
  const known = new Map(previous.map((photo) => [photo.key, photo]));
  let changed = photos.length !== previous.length;
  const next = photos.map((photo) => {
    const old = known.get(photo.key);
    if (
      old?.size === photo.size &&
      old.modified === photo.modified &&
      old.negative === photo.negative
    )
      return old;
    changed = true;
    return photo;
  });
  return changed ? next : previous;
}

// Folders, their photos, and per-photo records (rating, saved edit). Nothing is
// read until the library is first shown.
export function usePhotoLibrary(active) {
  const [folders, setFolders] = useState([]),
    [records, setRecords] = useState(() => new Map()),
    [error, setError] = useState(null);
  const started = useRef(false),
    scans = useRef(new Map());

  const patchFolder = useCallback(
    (id, patch) =>
      setFolders((list) =>
        list.map((folder) =>
          folder.id === id ? { ...folder, ...patch } : folder,
        ),
      ),
    [],
  );
  const mergeRecords = useCallback(
    (list) =>
      list.length &&
      setRecords((current) => {
        const next = new Map(current);
        for (const record of list) next.set(record.key, record);
        return next;
      }),
    [],
  );

  // A folder shown from its saved list is refreshed quietly. A new one fills
  // in as it is read, less often as it grows, since each update re-sorts it.
  const scan = useCallback(
    async (folder) => {
      scans.current.get(folder.id)?.abort();
      const controller = new AbortController();
      scans.current.set(folder.id, controller);
      const refreshing = folder.photos?.length > 0;
      patchFolder(folder.id, {
        status: "scanning",
        error: null,
        ...(refreshing ? {} : { photos: [] }),
      });
      let shown = 0;
      try {
        const photos = await scanDirectory(folder, {
          signal: controller.signal,
          onProgress: refreshing
            ? null
            : (found) => {
                const now = performance.now();
                if (now - shown < Math.max(160, found.length / 25)) return;
                shown = now;
                patchFolder(folder.id, { photos: found.slice() });
              },
        });
        setFolders((list) =>
          list.map((item) =>
            item.id === folder.id
              ? {
                  ...item,
                  status: "ready",
                  photos: keepUnchanged(item.photos, photos),
                }
              : item,
          ),
        );
        saveIndex(folder.id, indexRows(photos)).catch(() => {});
      } catch (reason) {
        if (reason.name !== "AbortError")
          patchFolder(folder.id, {
            status: "error",
            error: message(reason, "This folder could not be read."),
            photos: [],
          });
      } finally {
        if (scans.current.get(folder.id) === controller)
          scans.current.delete(folder.id);
      }
    },
    [patchFolder],
  );

  // Chromium keeps a stored folder's permission for the origin, but may ask
  // again after a restart; asking needs a click, so it waits for one.
  const connect = useCallback(
    async (folder, ask = false) => {
      const options = { mode: "read" };
      let state = (await folder.handle.queryPermission?.(options)) ?? "granted";
      if (state !== "granted" && ask)
        state = await folder.handle
          .requestPermission(options)
          .catch(() => "denied");
      if (state === "granted") return scan(folder);
      patchFolder(folder.id, { status: "permission" });
    },
    [scan, patchFolder],
  );

  useEffect(() => {
    if (!active || started.current) return;
    started.current = true;
    // Saved folders show their last photo list and records at once, then
    // are read again for changes.
    loadFolders()
      .then(async (list) => {
        list.sort((a, b) => a.added - b.added);
        list = list.map((folder) => ({
          ...folder,
          handle: folderAccess().revive(folder.handle),
        }));
        const saved = await Promise.all(
          list.map((folder) =>
            Promise.all([
              loadIndex(folder.id).catch(() => null),
              loadPhotoRecords(folder.id).catch(() => []),
            ]),
          ),
        );
        const shown = list.map((folder, index) => ({
          ...folder,
          status: "scanning",
          photos: indexedPhotos(folder, saved[index][0] ?? []),
        }));
        mergeRecords(saved.flatMap(([, records]) => records));
        setFolders((current) => [...shown, ...current]);
        shown.forEach((folder) => connect(folder));
      })
      .catch(() =>
        setError(
          "The library could not be opened. Folders added now last for this session.",
        ),
      );
  }, [active, connect, mergeRecords]);

  useEffect(() => onRecordChange(mergeRecords), [mergeRecords]);
  useEffect(
    () => () => scans.current.forEach((controller) => controller.abort()),
    [],
  );

  // Marks a folder as holding scanned negatives, or not: its photos open, and show, as negatives.
  const markNegative = useCallback(
    (id, negative) => {
      const folder = folders.find((item) => item.id === id);
      if (!folder || !!folder.negative === negative) return;
      setFolders((list) =>
        list.map((item) =>
          item.id === id
            ? {
                ...item,
                negative,
                photos: item.photos.map((photo) => ({ ...photo, negative })),
              }
            : item,
        ),
      );
      if (!folder.transient && folder.handle)
        saveFolder(stored({ ...folder, negative })).catch(() =>
          setError("The folder could not be saved in this browser."),
        );
    },
    [folders],
  );

  // Resolves the folder's id, or null when the picker was dismissed. A folder of scanned
  // negatives is added with `negative`.
  const addFolder = useCallback(async ({ negative = false } = {}) => {
    let handle;
    try {
      handle = await folderAccess().choose();
    } catch (reason) {
      setError(message(reason, "The folder could not be opened."));
      return null;
    }
    if (!handle) return null;
    for (const folder of folders)
      if (
        folder.handle &&
        (await folder.handle.isSameEntry(handle).catch(() => false))
      ) {
        if (negative && !folder.negative) markNegative(folder.id, true);
        else scan(folder);
        return folder.id;
      }
    const folder = {
      id: crypto.randomUUID(),
      name: handle.name,
      handle,
      added: Date.now(),
      negative,
    };
    const saved = await saveFolder(stored(folder)).then(
      () => true,
      () => false,
    );
    // Ask the browser to keep ratings and edits under storage pressure;
    // Chromium decides without prompting.
    if (saved) navigator.storage?.persist?.().catch(() => {});
    setFolders((list) => [
      ...list,
      { ...folder, transient: !saved, status: "scanning", photos: [] },
    ]);
    scan(folder);
    return folder.id;
  }, [folders, scan, markNegative]);

  // Browsers without a directory picker upload the folder instead; it lasts for
  // the session, but its ratings and edits are kept under the folder's name.
  const addUploadedFiles = useCallback(
    async (files, { negative = false } = {}) => {
      const added = uploadedFolders(files, negative);
      for (const folder of added)
        mergeRecords(await loadPhotoRecords(folder.id).catch(() => []));
      setFolders((list) => [
        ...list.filter(
          (folder) => !added.some((item) => item.id === folder.id),
        ),
        ...added.map((folder) => ({
          ...folder,
          added: Date.now(),
          status: "ready",
        })),
      ]);
      return added[0]?.id ?? null;
    },
    [mergeRecords],
  );

  const removeFolder = useCallback(async (id) => {
    scans.current.get(id)?.abort();
    folders.find((folder) => folder.id === id)?.handle?.forget?.();
    await forgetFolder(id).catch(() => {});
    setFolders((list) => list.filter((folder) => folder.id !== id));
    setRecords((current) => {
      const next = new Map(current);
      for (const key of current.keys())
        if (key.startsWith(`${id}/`)) next.delete(key);
      return next;
    });
  }, [folders]);

  // A folder's photos replaced, and kept as its index.
  const replacePhotos = useCallback(
    (folder, photos) => {
      patchFolder(folder.id, { photos });
      saveIndex(folder.id, indexRows(photos)).catch(() => {});
    },
    [patchFolder],
  );

  // Renames a photo in its folder; its rating, edit and thumbnail follow it. Resolves
  // {from, to, name}, its old and new keys, or null when the folder's host refused.
  const renamePhoto = useCallback(
    async (photo, name) => {
      const folder = folders.find((item) => item.id === photo.folderId);
      let path;
      try {
        path = await photo.root.rename(photo.path, name);
      } catch (reason) {
        setError(message(reason, `${photo.name} could not be renamed.`));
        return null;
      }
      const renamed = photoEntry(folder, path, photo.size, photo.modified);
      replacePhotos(
        folder,
        folder.photos.map((item) => (item.key === photo.key ? renamed : item)),
      );
      await movePhoto(photo.key, renamed.key).catch(() => {});
      setRecords((current) => {
        if (!current.has(photo.key)) return current;
        const next = new Map(current);
        next.set(renamed.key, { ...current.get(photo.key), key: renamed.key });
        next.delete(photo.key);
        return next;
      });
      return { from: photo.key, to: renamed.key, name: renamed.name };
    },
    [folders, replacePhotos],
  );

  // Moves photos to the trash, folder by folder; they leave the library with their records.
  // Resolves the keys of the photos trashed.
  const trashPhotos = useCallback(
    async (photos) => {
      const removed = [],
        problems = [];
      for (const folder of folders) {
        const chosen = photos.filter((photo) => photo.folderId === folder.id);
        if (!chosen.length) continue;
        let result;
        try {
          result = await folder.handle.trash(chosen.map((photo) => photo.path));
        } catch (reason) {
          problems.push(message(reason, "The photos could not be moved to the Trash."));
          continue;
        }
        const trashed = new Set(result.trashed);
        for (const failure of result.failed)
          problems.push(`${failure.path.split("/").at(-1)}: ${failure.message}`);
        if (!trashed.size) continue;
        const keys = chosen
          .filter((photo) => trashed.has(photo.path))
          .map((photo) => photo.key);
        removed.push(...keys);
        replacePhotos(
          folder,
          folder.photos.filter((photo) => !trashed.has(photo.path)),
        );
      }
      if (removed.length) {
        await forgetPhotos(removed).catch(() => {});
        setRecords((current) => {
          const next = new Map(current);
          for (const key of removed) next.delete(key);
          return next;
        });
      }
      if (problems.length) setError(problems.join(" "));
      return removed;
    },
    [folders, replacePhotos],
  );

  // Stars change at once; the records follow when they are saved.
  const rate = useCallback((keys, rating) => {
    setRecords((current) => {
      const next = new Map(current);
      for (const key of keys)
        next.set(key, { ...current.get(key), key, rating });
      return next;
    });
    updatePhotoRecords(keys, { rating }).catch(() =>
      setError("Ratings could not be saved in this browser."),
    );
  }, []);

  return {
    folders,
    records,
    error,
    dismissError: () => setError(null),
    addFolder,
    addUploadedFiles,
    markNegative,
    removeFolder,
    rescan: (folder) => (folder.handle ? connect(folder, true) : null),
    rate,
    renamePhoto,
    trashPhotos,
  };
}
