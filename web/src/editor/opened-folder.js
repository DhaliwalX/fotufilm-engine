import { photoEntry } from "../photo-library/library-scan.js";
import { sortedPhotos } from "../photo-library/library-model.js";
import { isFilmPack } from "./useFilmPacks.js";

// One file opened on its own (Open…, Finder, Open Recent) brings the pictures beside it into the
// strip, as a library photo brings its roll (openedPhotos): those of its folder, not of folders
// below, in the library's name order, the file opened shown. Several files open as chosen.

/** The strip's items for `path` among `rows`, its folder's [[name, size, modified]]. */
export function folderItems(path, rows) {
  const slash = path.lastIndexOf("/");
  const folder = path.slice(0, slash),
    name = path.slice(slash + 1);
  const entries = rows.map(([file, size, modified]) =>
    photoEntry({ id: "opened" }, file, size, modified),
  );
  if (!entries.some((entry) => entry.path === name))
    return [{ path, name, shown: true }];
  return sortedPhotos([entries], new Map()).map((entry) => ({
    path: `${folder}/${entry.path}`,
    name: entry.name,
    shown: entry.path === name,
  }));
}

/** `items` ({path, name}) as they open: one photograph with its folder, where the host lists it. */
export async function withOpenedFolder(backend, items) {
  if (
    items.length !== 1 ||
    isFilmPack(items[0].name) ||
    !backend?.listOpenedFolder
  )
    return items;
  try {
    return folderItems(
      items[0].path,
      await backend.listOpenedFolder(items[0].path),
    );
  } catch {
    // A folder that cannot be read opens the file alone.
    return items;
  }
}
