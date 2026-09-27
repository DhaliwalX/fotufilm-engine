import { parseEdit } from "./editor-state.js";
import { validateStockSettings } from "./stock-settings.js";
import { isVideoFile } from "./media-types.js";

// Every photograph keeps its last edit, as the Mac app's shelf does (shared/FotufilmApp/
// EditLibrary.swift): opening it again starts where it was left. An edit is kept as opaque text
// under the photograph's key — a photo-library key, or the identity of a file opened on its own —
// in an edit store: `{load(key) → text | null, save(key, text | null)}`, where `null` forgets it.

// The text an edit is kept as; the same as Save Edits writes.
export const editText = (edit) => JSON.stringify({ version: 1, edit });

// A kept edit for the films installed now; throws when it cannot be used.
export function restoreEdit(text, stocks) {
  const edit = parseEdit(
    text,
    stocks.map((stock) => stock.id),
  );
  validateStockSettings(
    edit,
    stocks.find((stock) => stock.id === edit.stock),
  );
  return edit;
}

// Stills are read whole to decode them anyway; past this they are known by name, size and date.
const DIGEST_LIMIT = 256 * 1024 * 1024;

// What a file opened on its own is known by. A still is known by its contents, as the Mac app
// knows it ("sha256:…"), so a renamed or moved copy keeps its edit; a movie, too large to read
// for it, by its name, size and date.
export async function fileIdentity(file) {
  if (!file) return null;
  if (!isVideoFile(file) && file.size <= DIGEST_LIMIT && globalThis.crypto?.subtle) {
    const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
    return `sha256:${Array.from(new Uint8Array(digest), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("")}`;
  }
  return `file:${file.name}|${file.size}|${file.lastModified}`;
}

// The key and kept edit of a document about to open: its library key (`editKey`), otherwise the
// identity the backend answered for a file it opened, otherwise the file's own. A kept edit that
// no longer fits (a film since removed) is reported as `problem` and the photograph opens fresh.
// Never rejects: a store that cannot be read opens the photograph fresh too.
export async function findSavedEdit(store, stocks, { editKey = null, file, identity }) {
  let key = editKey ?? identity ?? null;
  if (!key && file) key = await fileIdentity(file).catch(() => null);
  if (!key) return { editKey: null, savedEdit: null };
  const text = await Promise.resolve()
    .then(() => store.load(key))
    .catch(() => null);
  if (!text) return { editKey: key, savedEdit: null };
  try {
    return { editKey: key, savedEdit: restoreEdit(text, stocks) };
  } catch (error) {
    return {
      editKey: key,
      savedEdit: null,
      problem: `the saved edit was not restored. ${error.message}`,
    };
  }
}

// The backend's own store when it keeps edits itself (`loadEdit`/`saveEdit`, for a host that
// keeps them beside its other files), and `fallback` otherwise.
export function editStore(backend, fallback) {
  if (typeof backend?.loadEdit === "function" && typeof backend?.saveEdit === "function")
    return { load: backend.loadEdit, save: backend.saveEdit };
  return fallback;
}
