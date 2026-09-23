// AbortSignal and callbacks stay in JavaScript. Only data crosses WebKit IPC.
export function createTransport(channel) {
  if (typeof channel?.postMessage !== "function")
    throw new Error("Invalid macOS image bridge.");
  return async function call(method, params = {}, { signal, onProgress } = {}) {
    signal?.throwIfAborted();
    const id = crypto.randomUUID();
    const report = (event) => {
      if (event.detail?.id === id) onProgress?.(event.detail.progress);
    };
    if (onProgress) globalThis.addEventListener("fotufilm-native-progress", report);
    const abort = () => {
      channel.postMessage({ id, method: "cancel" }).catch(() => {});
    };
    signal?.addEventListener("abort", abort, { once: true });
    try {
      const result = await channel.postMessage({
        id,
        method,
        params: JSON.parse(JSON.stringify(params)),
      });
      if (signal?.aborted) {
        if (result?.handle)
          await channel.postMessage({
            id: crypto.randomUUID(),
            method: "release",
            params: { handle: result.handle },
          });
        signal.throwIfAborted();
      }
      return result;
    } finally {
      signal?.removeEventListener("abort", abort);
      if (onProgress) globalThis.removeEventListener("fotufilm-native-progress", report);
    }
  };
}
export function imageBlob(encoded, type = "image/png") {
  const bytes = Uint8Array.from(atob(encoded), (value) => value.charCodeAt(0));
  return new Blob([bytes], { type });
}
export async function fileBase64(file) {
  if (file.size > 512 * 1024 * 1024)
    throw new Error("Native preview supports files up to 512 MB.");
  const bytes = new Uint8Array(await file.arrayBuffer()),
    chunks = [];
  for (let i = 0; i < bytes.length; i += 16384)
    chunks.push(String.fromCharCode(...bytes.subarray(i, i + 16384)));
  return btoa(chunks.join(""));
}
export function importedImage(result) {
  const { preview, ...image } = result;
  const url = URL.createObjectURL(imageBlob(preview));
  return { image: { ...image, src: url }, url };
}
