// How the library reaches folders. A browser uses the File System Access API; a desktop host that
// reads folders itself installs its own access (backend/desktop/library-folders.js), since
// Chromium's picker refuses a home, Documents, Desktop or Downloads folder as a whole.
//
// An access offers `persistent()`, whether added folders outlast the session; `choose()`, a
// folder handle or null when the picker is dismissed; and `revive(handle)`, a stored handle made
// usable again. A host's handles also offer `files(signal)`, the folder's [path, size, modified]
// rows in one call, `file(path, modified)`, `thumbnail(path, maxEdge)`, an image blob or null
// when the host draws none, `forget()`, and `rename(path, name)`, the photo's new path. Where
// `fileActions` names them ({reveal, trash}, the menu's words), `reveal(paths)` shows photos in
// the file manager and `trash(paths)` moves them to the trash.
const browserAccess = {
  persistent: () => typeof globalThis.showDirectoryPicker === "function",
  async choose() {
    try {
      return await globalThis.showDirectoryPicker({
        id: "fotufilm-library",
        mode: "read",
      });
    } catch (reason) {
      if (reason.name === "AbortError") return null;
      throw reason;
    }
  },
  revive: (handle) => handle,
};

let access = browserAccess;

export const folderAccess = () => access;
export function installFolderAccess(provider) {
  access = provider ?? browserAccess;
}
