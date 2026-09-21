import { canvasColorSpace } from "./canvas-color.js";
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
  return new Promise((resolve, reject) => {
    let worker;
    const finish = (error, blob) => {
      worker?.terminate();
      bitmap.close();
      if (error) reject(new Error(error));
      else resolve(blob);
    };
    try {
      worker = new Worker(
        new URL("./canvas-encoder-worker.js", import.meta.url),
        { type: "module" },
      );
      worker.onmessage = ({ data }) => finish(data.error, data.blob);
      worker.onerror = (event) =>
        finish(event.message || "Image encoding failed.");
      worker.postMessage(
        { bitmap, type, quality, colorSpace: canvasColorSpace(canvas) },
        [bitmap],
      );
    } catch (error) {
      finish(error.message);
    }
  });
}
