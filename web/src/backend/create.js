import { validateBackend } from "./contract.js";
import { createNativeBackend } from "./native.js";

export async function createBackend(nativeHost, nativeTransport) {
  if (nativeHost !== undefined) return createNativeBackend(nativeHost);
  if (nativeTransport !== undefined) {
    const { createMacBackend } = await import("./macos/host.js");
    return createNativeBackend(createMacBackend(nativeTransport));
  }
  const { createBrowserBackend } = await import("./browser.js");
  return validateBackend(createBrowserBackend());
}
