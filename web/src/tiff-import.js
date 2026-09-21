import { assetUrl } from "./engine.js";
import { LinearImage } from "./linear-image.js";
import { decodeImageWorker } from "./image-worker.js";
import { attachLinearPreview } from "./linear-preview.js";
import { readPhotoMetadata } from "./photo-metadata.js";

export function isTIFF(header) {
  return (
    header.length >= 4 &&
    ((header[0] === 73 &&
      header[1] === 73 &&
      (header[2] === 42 || header[2] === 43) &&
      header[3] === 0) ||
      (header[0] === 77 &&
        header[1] === 77 &&
        header[2] === 0 &&
        (header[3] === 42 || header[3] === 43)))
  );
}
export async function importTIFF(file, options = {}) {
  const decoded = await decodeImageWorker(
    file,
    () =>
      new Worker(new URL("./tiff-import-worker.js", import.meta.url), {
        type: "module",
      }),
    {
      ...options,
      label: "TIFF",
      message: {
        decoderURL: assetUrl("tiff/decoder.mjs"),
        linearSamples: !!options.linearSamples,
      },
    },
  );
  const image = new LinearImage(decoded);
  image.deep = { format: "TIFF", bitDepth: decoded.bitDepth };
  image.lensMetadata = await readPhotoMetadata(file, options);
  return attachLinearPreview(image, options);
}
