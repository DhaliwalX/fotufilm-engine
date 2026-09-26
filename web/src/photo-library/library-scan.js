import { libraryMediaKind } from "../media-types.js";

export const photoKey = (folderId, path) => `${folderId}/${path}`;

// Files whose size and date are read at once while walking a folder.
const READS = 32;

// Natural, case- and accent-insensitive order ("IMG_9" before "IMG_10"),
// computed once per photo so sorting a large library compares plain strings.
const natural = (text) =>
  text
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/\d+/g, (digits) => digits.padStart(12, "0"));

// Photos in a picked folder keep only its root handle and are reopened by
// path; uploaded ones keep their File.
export function photoEntry(folder, path, size, modified, file = null) {
  const name = path.slice(path.lastIndexOf("/") + 1);
  // "Photo.jpg" before "Photo 2.jpg", and a raw beside its JPEG.
  const dot = name.lastIndexOf("."),
    stem = dot > 0 ? name.slice(0, dot) : name,
    extension = dot > 0 ? name.slice(dot + 1) : "";
  return {
    key: photoKey(folder.id, path),
    folderId: folder.id,
    path,
    name,
    kind: libraryMediaKind(name),
    size,
    modified,
    order: [stem, extension, path].map(natural).join("\0"),
    root: folder.handle ?? null,
    file,
  };
}

// Walk a directory handle depth first. Hidden files and folders (".git",
// ".thumbnails", macOS "._" resource forks) are skipped, and a file deleted
// during the walk is left out.
export async function scanDirectory(folder, { signal, onProgress } = {}) {
  const photos = [],
    reading = new Set();
  let failure = null;
  const read = (handle, path) =>
    handle.getFile().then(
      (file) => {
        photos.push(photoEntry(folder, path, file.size, file.lastModified));
        onProgress?.(photos);
      },
      (error) => {
        if (error.name !== "NotFoundError") failure ??= error;
      },
    );
  async function walk(directory, prefix) {
    for await (const [name, handle] of directory.entries()) {
      if (signal?.aborted)
        throw new DOMException("Scan cancelled.", "AbortError");
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
  await walk(folder.handle, "");
  await Promise.all(reading);
  if (failure) throw failure;
  return photos;
}

// A folder's photos as saved between visits, so a large folder shows at once
// while it is read again.
export const indexRows = (photos) =>
  photos.map(({ path, size, modified }) => [path, size, modified]);
export const indexedPhotos = (folder, rows) =>
  rows
    .map(([path, size, modified]) => photoEntry(folder, path, size, modified))
    .filter((photo) => photo.kind);

// Browsers without a directory picker upload a folder as a flat file list
// whose webkitRelativePath starts with the chosen folder's name.
export function uploadedFolders(files) {
  const folders = new Map();
  for (const file of Array.from(files || [])) {
    const [root, ...rest] = (file.webkitRelativePath || file.name).split("/");
    const path = rest.join("/");
    if (
      !path ||
      !libraryMediaKind(file.name) ||
      path.split("/").some((part) => part.startsWith("."))
    )
      continue;
    const id = `upload:${root}`;
    if (!folders.has(id))
      folders.set(id, { id, name: root, transient: true, photos: [] });
    const folder = folders.get(id);
    folder.photos.push(
      photoEntry(folder, path, file.size, file.lastModified, file),
    );
  }
  return [...folders.values()];
}

// Read the file again so one edited or replaced since the scan opens as it
// is now.
export async function currentFile(photo) {
  if (!photo.root) return photo.file;
  const parts = photo.path.split("/");
  let directory = photo.root;
  for (const part of parts.slice(0, -1))
    directory = await directory.getDirectoryHandle(part);
  return (await directory.getFileHandle(parts.at(-1))).getFile();
}
