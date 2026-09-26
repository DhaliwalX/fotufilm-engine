import { colorContext } from "./canvas-color.js";
import { storedPng } from "./png-stored.js";
self.onmessage = async ({ data }) => {
  const { id, bitmap, type, quality, colorSpace } = data;
  if (data.pixels) {
    self.postMessage({
      id,
      blob: storedPng(data.pixels, data.width, data.height, colorSpace),
    });
    return;
  }
  try {
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    colorContext(canvas, colorSpace).drawImage(bitmap, 0, 0);
    bitmap.close();
    const blob = await canvas.convertToBlob({ type, quality });
    if (blob.type !== type)
      throw new Error("This browser cannot export that format. Choose PNG.");
    self.postMessage({ id, blob });
  } catch (error) {
    bitmap.close();
    self.postMessage({ id, error: error.message });
  }
};
