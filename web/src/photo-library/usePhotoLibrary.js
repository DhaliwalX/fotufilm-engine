import { useCallback, useEffect, useRef, useState } from "react";
import {
  forgetFolder,
  loadFolders,
  loadPhotoRecords,
  onRecordChange,
  saveFolder,
  updatePhotoRecord,
} from "./library-store.js";
import { scanDirectory, uploadedFolders } from "./library-scan.js";

export const supportsFolderAccess = () =>
  typeof globalThis.showDirectoryPicker === "function";

const stored = ({ id, name, handle, added }) => ({ id, name, handle, added });
const message = (error, fallback) =>
  error?.name === "NotFoundError"
    ? "This folder has moved or been deleted."
    : error?.message || fallback;

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

  const scan = useCallback(
    async (folder) => {
      scans.current.get(folder.id)?.abort();
      const controller = new AbortController();
      scans.current.set(folder.id, controller);
      patchFolder(folder.id, { status: "scanning", error: null, photos: [] });
      let shown = 0;
      try {
        const [photos, saved] = await Promise.all([
          scanDirectory(folder, {
            signal: controller.signal,
            // Fill the grid as the walk goes, a few times a second.
            onProgress(found) {
              const now = performance.now();
              if (now - shown < 160) return;
              shown = now;
              patchFolder(folder.id, { photos: found.slice() });
            },
          }),
          loadPhotoRecords(folder.id).catch(() => []),
        ]);
        mergeRecords(saved);
        patchFolder(folder.id, { status: "ready", photos });
      } catch (reason) {
        if (reason.name !== "AbortError")
          patchFolder(folder.id, {
            status: "error",
            error: message(reason, "This folder could not be read."),
          });
      } finally {
        if (scans.current.get(folder.id) === controller)
          scans.current.delete(folder.id);
      }
    },
    [patchFolder, mergeRecords],
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
    loadFolders()
      .then((list) => {
        list.sort((a, b) => a.added - b.added);
        setFolders((current) => [
          ...list.map((folder) => ({
            ...folder,
            status: "scanning",
            photos: [],
          })),
          ...current,
        ]);
        list.forEach((folder) => connect(folder));
      })
      .catch(() =>
        setError(
          "The library could not be opened. Folders added now last for this session.",
        ),
      );
  }, [active, connect]);

  useEffect(
    () => onRecordChange((record) => mergeRecords([record])),
    [mergeRecords],
  );
  useEffect(
    () => () => scans.current.forEach((controller) => controller.abort()),
    [],
  );

  // Resolves the folder's id, or null when the picker was dismissed.
  const addFolder = useCallback(async () => {
    let handle;
    try {
      handle = await globalThis.showDirectoryPicker({
        id: "fotufilm-library",
        mode: "read",
      });
    } catch (reason) {
      if (reason.name !== "AbortError")
        setError(message(reason, "The folder could not be opened."));
      return null;
    }
    for (const folder of folders)
      if (folder.handle && (await folder.handle.isSameEntry(handle))) {
        scan(folder);
        return folder.id;
      }
    const folder = {
      id: crypto.randomUUID(),
      name: handle.name,
      handle,
      added: Date.now(),
    };
    const saved = await saveFolder(stored(folder)).then(
      () => true,
      () => false,
    );
    setFolders((list) => [
      ...list,
      { ...folder, transient: !saved, status: "scanning", photos: [] },
    ]);
    scan(folder);
    return folder.id;
  }, [folders, scan]);

  // Browsers without a directory picker upload the folder instead; it lasts for
  // the session, but its ratings and edits are kept under the folder's name.
  const addUploadedFiles = useCallback(
    async (files) => {
      const added = uploadedFolders(files);
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
    await forgetFolder(id).catch(() => {});
    setFolders((list) => list.filter((folder) => folder.id !== id));
    setRecords((current) => {
      const next = new Map(current);
      for (const key of current.keys())
        if (key.startsWith(`${id}/`)) next.delete(key);
      return next;
    });
  }, []);

  const rate = useCallback((keys, rating) => {
    for (const key of keys)
      updatePhotoRecord(key, { rating }).catch(() =>
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
    removeFolder,
    rescan: (folder) => (folder.handle ? connect(folder, true) : null),
    rate,
  };
}
