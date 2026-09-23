import { videoColorParameters } from "./video-color-parameters.js";
import { VideoColorGPU } from "./video-color-gpu.js";
import { decodeVideoPlanes } from "./video-color.js";
import { orientVideoPixels } from "./video-frame-geometry.js";

async function prepareGPU() {
  let expired = false,
    timer;
  const attempt = VideoColorGPU.create()
    .then((value) => {
      if (expired) {
        value?.dispose();
        return null;
      }
      return value;
    })
    .catch(() => null);
  try {
    return await Promise.race([
      attempt,
      new Promise((resolve) => {
        timer = setTimeout(() => {
          expired = true;
          resolve(null);
        }, 15000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
let gpu = prepareGPU(),
  queue = Promise.resolve();
async function handle({ id, frame, encoding }) {
  try {
    let decoder = await gpu;
    if (!frame) {
      postMessage({ id, ready: !!decoder });
      return;
    }
    videoColorParameters(frame, encoding);
    let pixels;
    if (decoder) {
      try {
        pixels = await decoder.decode(frame, encoding);
      } catch {
        decoder.dispose();
        gpu = Promise.resolve(null);
      }
    }
    const image = pixels
      ? {
          naturalWidth: frame.displayWidth,
          naturalHeight: frame.displayHeight,
          linear: { data: pixels, colors: 4 },
        }
      : orientVideoPixels(
          decodeVideoPlanes(frame, encoding),
          frame,
          frame.width,
          frame.height,
        );
    postMessage({ id, image }, [image.linear.data.buffer]);
  } catch (error) {
    postMessage({ id, error: error.message });
  }
}
self.onmessage = ({ data }) => {
  queue = queue.then(() => handle(data));
};
