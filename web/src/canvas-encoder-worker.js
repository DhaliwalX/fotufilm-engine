self.onmessage = async ({ data: { bitmap, type, quality } }) => {
  try {
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    canvas.getContext("2d").drawImage(bitmap, 0, 0);
    bitmap.close();
    const blob = await canvas.convertToBlob({ type, quality });
    if (blob.type !== type)
      throw new Error("This browser cannot export that format. Choose PNG.");
    self.postMessage({ blob });
  } catch (error) {
    bitmap.close();
    self.postMessage({ error: error.message });
  }
};
