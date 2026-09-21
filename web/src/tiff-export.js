// Ownership of export pixels moves to this short-lived encoder, keeping large
// strip packing and Blob construction off the UI thread.
export function exportTiff({ pixels, width, height, colorSpace }) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./tiff-worker.js", import.meta.url), {
      type: "module",
    });
    const finish = (error, blob) => {
      worker.terminate();
      if (error) reject(new Error(error));
      else resolve(blob);
    };
    worker.onmessage = ({ data }) => finish(data.error, data.blob);
    worker.onerror = (event) =>
      finish(event.message || "TIFF encoding failed.");
    try {
      worker.postMessage({ pixels, width, height, colorSpace }, [pixels.buffer]);
    } catch (error) {
      finish(error.message);
    }
  });
}
