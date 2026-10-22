import { exportTiff } from "../tiff-export.js";
import { DPX_TYPE, encodeDPX } from "../dpx.js";
import { canvasBlob } from "../geometry.js";
import { download } from "../editor/file-download.js";
import {
  createVideoDestination,
  exportVideo as encodeVideo,
} from "../video-export.js";

export async function exportImage({
  session,
  type,
  quality,
  filename,
  ...request
}) {
  const dpx = type === DPX_TYPE;
  const next = await session.render({
    ...request,
    // A Cineon Log scan is the photograph alone: no print frame around it.
    ...(dpx ? { edit: { ...request.edit, printFrame: "none" } } : {}),
    comparison: false,
    purpose: "export",
    bitDepth: type === "image/tiff" || dpx ? 16 : 8,
  });
  if (!next) throw new DOMException("Export cancelled.", "AbortError");
  request.onProgress?.(`Encoding ${dpx ? "DPX" : type.split("/")[1].toUpperCase()} export`);
  const blob = dpx
    ? encodeDPX({ ...next, stock: request.stock })
    : type === "image/tiff"
      ? await exportTiff(next)
      : type === "image/png"
        ? next.blob
        : await canvasBlob(next.canvas, type, quality);
  download(blob, filename);
}
export async function exportVideo({ filename, ...request }) {
  const destination = await createVideoDestination(filename);
  return encodeVideo({ ...request, destination });
}
