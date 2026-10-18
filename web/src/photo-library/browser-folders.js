// Library folders in a browser, for the Flutter editor's library (flutter-bridge.js). A folder
// picked with the File System Access API keeps its handle in IndexedDB, where Chromium keeps its
// read permission per origin; without a directory picker (Firefox, Safari) a folder is uploaded
// and lasts for the visit. The library names each folder `/folders/<id>/<name>` and each photo
// by its path below that; nothing leaves the browser.
import { libraryMediaKind } from "../media-types.js";

const ROOT = "/folders/";
// Files whose size and date are read at once while walking a folder.
const READS = 32;
const uploads = new Map();
let database;

function openDatabase() {
  database ??= new Promise((resolve, reject) => {
    const request = indexedDB.open("fotufilm-library-folders", 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore("handles", { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).catch((error) => {
    database = null;
    throw error;
  });
  return database;
}
async function store(mode, work) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction("handles", mode);
    const request = work(transaction.objectStore("handles"));
    transaction.oncomplete = () => resolve(request.result);
    transaction.onerror = transaction.onabort = () =>
      reject(transaction.error || new Error("The library could not be saved."));
  });
}

/// `/folders/<id>/<name>/<path…>` as {id, name, path}, or null for any other path.
export function parseFolderPath(path) {
  if (typeof path !== "string" || !path.startsWith(ROOT)) return null;
  const [id, name, ...rest] = path.slice(ROOT.length).split("/");
  return id && name ? { id, name, path: rest.join("/") } : null;
}

/// The library's name for a folder chosen now, or null when the picker was dismissed.
export async function chooseFolder() {
  if (typeof globalThis.showDirectoryPicker === "function") {
    let handle;
    try {
      handle = await globalThis.showDirectoryPicker({ id: "fotufilm-library", mode: "read" });
    } catch (error) {
      if (error.name === "AbortError") return null;
      throw error;
    }
    // A folder added before keeps its name, so it finds its ratings and edits.
    for (const record of await store("readonly", (handles) => handles.getAll()))
      if (await record.handle.isSameEntry(handle)) return `${ROOT}${record.id}/${handle.name}`;
    const id = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
    await store("readwrite", (handles) => handles.put({ id, handle }));
    return `${ROOT}${id}/${handle.name}`;
  }
  const files = await uploadFolder();
  if (!files?.length) return null;
  const name = (files[0].webkitRelativePath || files[0].name).split("/")[0];
  // The same name each time, so a folder added again finds its ratings and edits.
  const upload = `upload-${encodeURIComponent(name)}`;
  uploads.set(upload, uploadedFiles(files));
  return `${ROOT}${upload}/${name}`;
}

function uploadFolder() {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.webkitdirectory = true;
    input.multiple = true;
    input.addEventListener("change", () => resolve([...input.files]), { once: true });
    input.addEventListener("cancel", () => resolve(null), { once: true });
    input.click();
  });
}

// An uploaded folder's files by their path below it. Hidden files and folders are left out.
export function uploadedFiles(files) {
  const byPath = new Map();
  for (const file of files) {
    const path = (file.webkitRelativePath || file.name).split("/").slice(1).join("/");
    if (!path || !libraryMediaKind(file.name) || path.split("/").some((part) => part.startsWith(".")))
      continue;
    byPath.set(path, file);
  }
  return byPath;
}

async function directoryOf(id) {
  const record = await store("readonly", (handles) => handles.get(id));
  if (!record)
    throw new Error(
      "This browser reads a folder only while the page is open: add it again to see its photos.",
    );
  const { handle } = record;
  if ((await handle.queryPermission?.({ mode: "read" })) !== "granted") {
    // Asking again needs a click: Rescan is one.
    const answer = await handle.requestPermission?.({ mode: "read" }).catch(() => null);
    if (answer !== "granted")
      throw new Error(`Allow Fotufilm to read “${handle.name}” again: choose Rescan in its menu.`);
  }
  return handle;
}

/// Every photo below the folder `root` names, as [path, size, modified] rows, depth first.
/// Hidden files and folders (".git", macOS "._" forks) are left out, as is a file deleted
/// during the walk.
export async function listFolder(root) {
  const folder = parseFolderPath(root);
  if (!folder) throw new Error("This folder is not in the browser's library.");
  const uploaded = uploads.get(folder.id);
  if (uploaded)
    return [...uploaded].map(([path, file]) => [path, file.size, file.lastModified]);
  return walkDirectory(await directoryOf(folder.id));
}

export async function walkDirectory(root) {
  const rows = [],
    reading = new Set();
  let failure = null;
  const read = (handle, path) =>
    handle.getFile().then(
      (file) => rows.push([path, file.size, file.lastModified]),
      (error) => {
        if (error.name !== "NotFoundError") failure ??= error;
      },
    );
  async function walk(directory, prefix) {
    for await (const [name, handle] of directory.entries()) {
      if (failure) throw failure;
      if (name.startsWith(".")) continue;
      const path = prefix ? `${prefix}/${name}` : name;
      if (handle.kind === "directory") {
        await walk(handle, path);
        continue;
      }
      if (!libraryMediaKind(name)) continue;
      const task = read(handle, path).then(() => reading.delete(task));
      reading.add(task);
      if (reading.size >= READS) await Promise.race(reading);
    }
  }
  await walk(root, "");
  await Promise.all(reading);
  if (failure) throw failure;
  return rows;
}

/// The file at a library path, read as it is now.
export async function folderFile(path) {
  const folder = parseFolderPath(path);
  if (!folder?.path) throw new Error("This photo is not in the browser's library.");
  const uploaded = uploads.get(folder.id);
  if (uploaded) {
    const file = uploaded.get(folder.path);
    if (!file) throw new Error(`${folder.path.split("/").at(-1)} is no longer in its folder.`);
    return file;
  }
  let directory = await directoryOf(folder.id);
  const parts = folder.path.split("/");
  try {
    for (const part of parts.slice(0, -1)) directory = await directory.getDirectoryHandle(part);
    return await (await directory.getFileHandle(parts.at(-1))).getFile();
  } catch (error) {
    if (error.name === "NotFoundError")
      throw new Error(`${parts.at(-1)} is no longer in its folder.`);
    throw error;
  }
}

/// Forgets a removed folder's handle or upload.
export async function forgetFolder(root) {
  const folder = parseFolderPath(root);
  if (!folder) return;
  uploads.delete(folder.id);
  await store("readwrite", (handles) => handles.delete(folder.id)).catch(() => {});
}
