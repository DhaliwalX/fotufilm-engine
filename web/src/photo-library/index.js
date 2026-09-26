// The photo library is self-contained: the editor shows <PhotoLibrary>, receives
// the photos the user opens, and hands back each photo's edit as opaque text.
import { updatePhotoRecords } from "./library-store.js";

export { default as PhotoLibrary } from "./PhotoLibrary.jsx";

export const saveLibraryEdit = (key, edit) =>
  updatePhotoRecords([key], { edit, edited: Date.now() });
