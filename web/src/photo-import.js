import { isDeepPNG, importDeepPNG } from "./png-import.js";
import { assetUrl, decodeRGBA } from "./engine.js";
import { readPhotoMetadata } from "./photo-metadata.js";
import { decodeImageWorker } from "./image-worker.js";
import { LinearImage } from "./linear-image.js";

export async function importPhoto(
  file,
  { signal, onProgress = () => {} } = {},
) {
  if (signal?.aborted) throw new DOMException("Import cancelled.", "AbortError");
  const header = new Uint8Array(await file.slice(0, 33).arrayBuffer());
  if (isDeepPNG(header)) return importDeepPNG(file, { signal, onProgress });
  const url = URL.createObjectURL(file);
  try {
    const standard = new Image();
    standard.src = url;
    await standard.decode();
    if (signal?.aborted)
      throw new DOMException("Import cancelled.", "AbortError");
    if (standard.naturalWidth * standard.naturalHeight > 120000000)
      throw new Error("Images above 120 megapixels are not supported.");
    const metadata = await readPhotoMetadata(file, { signal });
    standard.lensMetadata = metadata;
    let image = standard;
    const signature = new Uint8Array(await file.slice(0, 2).arrayBuffer());
    if (signature[0] === 0xff && signature[1] === 0xd8) {
      onProgress("Reading JPEG highlight range");
      const scale = Math.min(
          1,
          256 / Math.max(standard.naturalWidth, standard.naturalHeight),
        ),
        canvas = document.createElement("canvas");
      canvas.width = Math.max(1, Math.round(standard.naturalWidth * scale));
      canvas.height = Math.max(1, Math.round(standard.naturalHeight * scale));
      const context = canvas.getContext("2d", { willReadFrequently: true });
      context.drawImage(standard, 0, 0, canvas.width, canvas.height);
      const reference = {
        width: canvas.width,
        height: canvas.height,
        pixels: decodeRGBA(
          context.getImageData(0, 0, canvas.width, canvas.height).data,
        ),
      };
      const decoded = await decodeImageWorker(
        file,
        () => new Worker(new URL("./hdr-worker.js", import.meta.url), { type: "module" }),
        {
          signal,
          onProgress,
          label: "HDR JPEG",
          message: {
            decoderURL: assetUrl("hdr/decoder.mjs"),
            orientation: metadata.orientation || 1,
            reference,
          },
        },
      );
      if (decoded) {
        if (
          decoded.width !== standard.naturalWidth ||
          decoded.height !== standard.naturalHeight
        )
          throw new Error(
            "The HDR and standard image orientations do not match.",
          );
        image = new LinearImage(decoded, standard);
        image.hdr = {
          format: "JPEG gain map",
          referenceGain: decoded.referenceGain,
        };
        image.src = url;
        image.lensMetadata = metadata;
      }
    }
    if (signal?.aborted)
      throw new DOMException("Import cancelled.", "AbortError");
    return { image, url };
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  }
}
