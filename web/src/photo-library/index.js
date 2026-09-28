// The photo library is self-contained: the editor shows <PhotoLibrary>, receives
// the photos the user opens, and hands back each photo's edit as opaque text. Its
// records also keep the edits of photos opened on their own, under their file
// identity (web/src/saved-edits.js), which no folder's keys can take.
import { loadPhotoRecord, updatePhotoRecords } from "./library-store.js";

export { default as PhotoLibrary } from "./PhotoLibrary.jsx";

export const loadLibraryEdit = (key) =>
  loadPhotoRecord(key).then((record) => record?.edit ?? null);
export const saveLibraryEdit = (key, edit) =>
  updatePhotoRecords([key], { edit, edited: Date.now() });
