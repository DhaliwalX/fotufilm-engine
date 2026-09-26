import { canvasColorSpace } from "./canvas-color.js";
import { storedPng } from "./png-stored.js";
export async function encodeCanvas(canvas, type = "image/png", quality = 0.95) {
  if (
    typeof OffscreenCanvas === "undefined" ||
    typeof createImageBitmap === "undefined"
  )
    return new Promise((resolve, reject) =>
      canvas.toBlob(
        (blob) => {
          if (!blob)
            reject(
              new Error(
                "Could not encode this image. Try a smaller export size.",
              ),
            );
          else if (blob.type !== type)
            reject(
              new Error("This browser cannot export that format. Choose PNG."),
            );
          else resolve(blob);
        },
        type,
        quality,
      ),
    );
  const bitmap = await createImageBitmap(canvas);
  return request(
    { bitmap, type, quality, colorSpace: canvasColorSpace(canvas) },
    [bitmap],
    () => bitmap.close(),
  );
}
// A transient preview skips compression: an uncompressed PNG of the same RGBA8 pixels encodes
// and decodes several times faster. Exports and kept thumbnails use encodeCanvas.
export function encodePreview(pixels, width, height, colorSpace = "srgb") {
  // Posting a view clones its whole buffer, which may be a WASM heap.
  if (pixels.byteOffset || pixels.byteLength !== pixels.buffer.byteLength)
    pixels = pixels.slice();
  if (typeof Worker === "undefined")
    return Promise.resolve(storedPng(pixels, width, height, colorSpace));
  return request({ pixels, width, height, colorSpace });
}
function request(message, transfer = [], abandon = () => {}) {
  return new Promise((resolve, reject) => {
    const id = ++lastRequest;
    pending.set(id, { resolve, reject });
    try {
      encoder().postMessage({ id, ...message }, transfer);
    } catch (error) {
      pending.delete(id);
      abandon();
      reject(new Error(error.message));
    }
  });
}
// One worker serves every encode: starting a module worker costs several
// milliseconds, which is most of a small preview frame's encode.
let worker = null,
  lastRequest = 0;
const pending = new Map();
function encoder() {
  if (worker) return worker;
  worker = new Worker(new URL("./canvas-encoder-worker.js", import.meta.url), {
    type: "module",
  });
  worker.onmessage = ({ data }) => {
    const request = pending.get(data.id);
    pending.delete(data.id);
    if (data.error) request?.reject(new Error(data.error));
    else request?.resolve(data.blob);
  };
  worker.onerror = (event) => {
    event.preventDefault?.();
    const message = event.message || "Image encoding failed.";
    worker.terminate();
    worker = null;
    for (const request of pending.values()) request.reject(new Error(message));
    pending.clear();
  };
  return worker;
}
