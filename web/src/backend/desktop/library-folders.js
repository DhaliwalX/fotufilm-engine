import { installFolderAccess } from "../../photo-library/folder-access.js";
import { LIBRARY_EXTENSIONS } from "../../media-types.js";
import { createTransport } from "./transport.js";

// A folder the desktop host reads (cef/src/app/library_methods.h). Only its path and name are
// stored with the library; the host keeps which folders were chosen, and serves only those.
class HostFolder {
  kind = "directory";
  #call;
  constructor(call, hostPath, name) {
    this.#call = call;
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
    return new File([blob], name, { type, lastModified: modified });
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
  installFolderAccess({
    persistent: () => true,
    async choose() {
      const chosen = await call("chooseLibraryFolder");
      return chosen ? new HostFolder(call, chosen.path, chosen.name) : null;
    },
    revive: (handle) =>
      handle?.hostPath ? new HostFolder(call, handle.hostPath, handle.name) : handle,
  });
}
