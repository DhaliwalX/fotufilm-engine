import { fileBase64, importedImage } from "./transport.js";

/** Keep movie bytes out of large WebKit messages and release partial imports on cancellation. */
export async function importVideo(call, file, { signal, onProgress } = {}) {
  const upload = await call("beginVideo", { name: file.name, size: file.size }, { signal });
  let result, preview, playbackUrl;
  try {
    const chunkSize = 512 * 1024;
    for (let offset = 0; offset < file.size; offset += chunkSize) {
      signal?.throwIfAborted();
      const chunk = file.slice(offset, offset + chunkSize);
      const data = await fileBase64(chunk);
      await call("appendVideo", { handle: upload.handle, offset, data }, { signal });
      onProgress?.(`Opening video · ${Math.round(100 * Math.min(file.size, offset + chunk.size) / file.size)}%`);
    }
    result = await call("importVideo", { handle: upload.handle }, { signal });
    playbackUrl = URL.createObjectURL(file);
    preview = importedImage(result);
    preview.image.video = { ...result.video, playbackUrl };
    return preview;
  } catch (error) {
    if (playbackUrl) URL.revokeObjectURL(playbackUrl);
    if (preview?.url) URL.revokeObjectURL(preview.url);
    if (result?.handle) await call("release", { handle: result.handle }).catch(() => {});
    throw error;
  } finally {
    await call("release", { handle: upload.handle }).catch(() => {});
  }
}
