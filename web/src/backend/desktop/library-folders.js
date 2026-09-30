import { installFolderAccess } from "../../photo-library/folder-access.js";
import { LIBRARY_EXTENSIONS } from "../../media-types.js";
import { createTransport, imageBlob } from "./transport.js";

// A folder the desktop host reads (cef/src/app/library_methods.h). Only its path and name are
// stored with the library; the host keeps which folders were chosen, and serves only those.
class HostFolder {
  kind = "directory";
  #call;
  #thumbnails;
  constructor(call, hostPath, name, thumbnails) {
    this.#call = call;
    this.#thumbnails = thumbnails;
    this.hostPath = hostPath;
    this.name = name;
  }
  async isSameEntry(other) {
    return other?.hostPath === this.hostPath;
  }
  async files(signal) {
    const result = await this.#call(
      "listLibraryFolder",
      { path: this.hostPath, extensions: LIBRARY_EXTENSIONS },
      { signal },
    );
    return JSON.parse(new TextDecoder().decode(result.payload));
  }
  async file(path, modified) {
    const name = path.slice(path.lastIndexOf("/") + 1);
    const response = await fetch(
      `/.library?path=${encodeURIComponent(`${this.hostPath}/${path}`)}`,
    );
    if (!response.ok)
      throw new DOMException(`${name} could not be read.`, "NotFoundError");
    const blob = await response.blob();
    const type = blob.type === "application/octet-stream" ? "" : blob.type;
    const file = new File([blob], name, { type, lastModified: modified });
    // Where the host reads it, so Export All can decode it in place.
    file.hostPath = `${this.hostPath}/${path}`;
    return file;
  }
  // The file's embedded preview, drawn by the host in place, so a thumbnail does not copy the
  // whole file into the page. Null when the host draws no thumbnails.
  async thumbnail(path, maxEdge) {
    if (!this.#thumbnails) return null;
    const result = await this.#call("thumbnail", {
      path: `${this.hostPath}/${path}`,
      maxEdge,
    });
    return imageBlob(result.thumbnail);
  }
  forget() {
    this.#call("forgetLibraryFolder", { path: this.hostPath }).catch(() => {});
  }
}

// Chromium's own picker refuses a home, Documents, Desktop or Downloads folder as a whole, so a
// host that reads folders itself (`libraryFolders`) picks and reads them for the library.
export function installLibraryFolders(channel) {
  if (channel?.capabilities?.libraryFolders !== true) return;
  const call = createTransport(channel);
  const thumbnails = channel.capabilities.thumbnails === true;
  installFolderAccess({
    persistent: () => true,
    async choose() {
      const chosen = await call("chooseLibraryFolder");
      return chosen ? new HostFolder(call, chosen.path, chosen.name, thumbnails) : null;
    },
    revive: (handle) =>
      handle?.hostPath
        ? new HostFolder(call, handle.hostPath, handle.name, thumbnails)
        : handle,
  });
}
