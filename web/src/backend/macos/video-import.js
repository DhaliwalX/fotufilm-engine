import { fileBase64, imageBlob, importedImage } from "./transport.js";

// A binary channel carries each chunk beside its message in shared memory; WebKit's carries
// base64 inside the JSON, which keeps its messages small.
const BINARY_CHUNK = 8 * 1024 * 1024;
const BASE64_CHUNK = 512 * 1024;

/**
 * Keep movie bytes out of large messages and release partial imports on cancellation.
 * `nativePlayback` asks the host for a clock the page can always play (the movie's sound as a
 * WAV), for a web view whose media element cannot decode the movie's own codecs.
 */
export async function importVideo(
  call,
  file,
  { signal, onProgress, binary = false, nativePlayback = false } = {},
) {
  const upload = await call("beginVideo", { name: file.name, size: file.size }, { signal });
  let result;
  try {
    const chunkSize = binary ? BINARY_CHUNK : BASE64_CHUNK;
    for (let offset = 0; offset < file.size; offset += chunkSize) {
      signal?.throwIfAborted();
      const chunk = file.slice(offset, offset + chunkSize);
      const params = { handle: upload.handle, offset };
      if (binary)
        await call("appendVideo", params, { signal, payload: await chunk.arrayBuffer() });
      else
        await call("appendVideo", { ...params, data: await fileBase64(chunk) }, { signal });
      onProgress?.(`Opening video · ${Math.round(100 * Math.min(file.size, offset + chunk.size) / file.size)}%`);
    }
    result = await call(
      "importVideo",
      { handle: upload.handle, playback: nativePlayback },
      { signal },
    );
    return importedVideo(result, nativePlayback ? null : file);
  } catch (error) {
    if (result?.handle) await call("release", { handle: result.handle }).catch(() => {});
    throw error;
  } finally {
    await call("release", { handle: upload.handle }).catch(() => {});
  }
}

/**
 * The editor's image for a native video answer: the first frame as its preview, and the
 * transport controls' clock from the host's playback payload, or from the original file.
 */
export function importedVideo(result, file = null) {
  const { playback, playbackType, ...answer } = result;
  let preview;
  const playbackUrl = playback
    ? URL.createObjectURL(imageBlob(playback, playbackType))
    : file
      ? URL.createObjectURL(file)
      : null;
  try {
    preview = importedImage(answer);
    preview.image.video = { ...answer.video, playbackUrl };
    return preview;
  } catch (error) {
    if (playbackUrl) URL.revokeObjectURL(playbackUrl);
    throw error;
  }
}
