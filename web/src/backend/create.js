import { validateBackend } from "./contract.js";
import { createNativeBackend } from "./native.js";

export async function createBackend(nativeHost, nativeTransport) {
  if (nativeHost !== undefined) return createNativeBackend(nativeHost);
  if (nativeTransport !== undefined) {
    const { createDesktopBackend } = await import("./desktop/host.js");
    return createNativeBackend(createDesktopBackend(nativeTransport));
  }
  const { createBrowserBackend } = await import("./browser.js");
  return validateBackend(createBrowserBackend());
}
