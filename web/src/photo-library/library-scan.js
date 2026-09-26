import { libraryMediaKind } from "../media-types.js";

export const photoKey = (folderId, path) => `${folderId}/${path}`;

function photoEntry(folderId, path, file, kind, handle) {
  return {
    key: photoKey(folderId, path),
    folderId,
    path,
    name: file.name,
    kind,
    size: file.size,
    modified: file.lastModified,
    file,
    handle,
  };
}

// Walk a directory handle depth first. Hidden files and folders (".git",
// ".thumbnails", macOS "._" resource forks) are skipped.
export async function scanDirectory(folder, { signal, onProgress } = {}) {
  const photos = [];
  async function walk(directory, prefix) {
    for await (const [name, handle] of directory.entries()) {
      if (signal?.aborted)
        throw new DOMException("Scan cancelled.", "AbortError");
      if (name.startsWith(".")) continue;
      const path = prefix ? `${prefix}/${name}` : name;
      if (handle.kind === "directory") {
        await walk(handle, path);
        continue;
      }
      const kind = libraryMediaKind(name);
      if (!kind) continue;
      photos.push(
        photoEntry(folder.id, path, await handle.getFile(), kind, handle),
      );
      onProgress?.(photos);
    }
  }
  await walk(folder.handle, "");
  return photos;
}

// Browsers without a directory picker upload a folder as a flat file list
// whose webkitRelativePath starts with the chosen folder's name.
export function uploadedFolders(files) {
  const folders = new Map();
  for (const file of Array.from(files || [])) {
    const [root, ...rest] = (file.webkitRelativePath || file.name).split("/");
    const path = rest.join("/");
    const kind = libraryMediaKind(file.name);
    if (!path || !kind || path.split("/").some((part) => part.startsWith(".")))
      continue;
    const id = `upload:${root}`;
    if (!folders.has(id))
      folders.set(id, { id, name: root, transient: true, photos: [] });
    folders.get(id).photos.push(photoEntry(id, path, file, kind));
  }
  return [...folders.values()];
}

// A File from a handle is a snapshot; read it again so an edited or replaced
// file opens as it is now.
export const currentFile = (photo) =>
  photo.handle ? photo.handle.getFile() : Promise.resolve(photo.file);
