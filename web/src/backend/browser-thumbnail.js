import { isVideoFile, isEXRFile, isRawFile } from "../media-types.js";

// A small picture of a photo opened with others, shown in the strip until it is chosen. The
// browser draws the formats it decodes itself; camera RAW, EXR and movies show their names.
export async function thumbnail({ file }, { maxEdge = 256 } = {}) {
  if (!file || isVideoFile(file) || isEXRFile(file) || isRawFile(file))
    return null;
  const bitmap = await createImageBitmap(file);
  try {
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
    const canvas = new OffscreenCanvas(
      Math.max(1, Math.round(bitmap.width * scale)),
      Math.max(1, Math.round(bitmap.height * scale)),
    );
    canvas
      .getContext("2d")
      .drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const blob = await canvas.convertToBlob({
      type: "image/jpeg",
      quality: 0.85,
    });
    return URL.createObjectURL(blob);
  } finally {
    bitmap.close();
  }
}
