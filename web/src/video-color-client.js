let worker,
  nextId = 0;
const pending = new Map();
function send(frame, encoding) {
  if (!worker) {
    worker = new Worker(new URL("./video-color-worker.js", import.meta.url), {
      type: "module",
    });
    worker.onmessage = ({ data }) => {
      const request = pending.get(data.id);
      if (!request) return;
      pending.delete(data.id);
      if (data.error) request.reject(new Error(data.error));
      else request.resolve(data.image ?? data.ready);
    };
    worker.onerror = () => {
      for (const request of pending.values())
        request.reject(
          new Error(
            "Video color conversion stopped. Try opening the video again.",
          ),
        );
      pending.clear();
      worker.terminate();
      worker = null;
    };
  }
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    try {
      worker.postMessage(
        { id, frame, encoding },
        frame ? [frame.data.buffer] : [],
      );
    } catch (error) {
      pending.delete(id);
      reject(error);
    }
  });
}
export async function prepareVideoColor() {
  if (typeof Worker === "undefined") return false;
  return send().catch(() => false);
}
export async function convertVideoFrame(frame, encoding) {
  if (typeof Worker !== "undefined") return send(frame, encoding);
  const [{ decodeVideoPlanes }, { orientVideoPixels }] = await Promise.all([
    import("./video-color.js"),
    import("./video-frame-geometry.js"),
  ]);
  return orientVideoPixels(
    decodeVideoPlanes(frame, encoding),
    frame,
    frame.width,
    frame.height,
  );
}
