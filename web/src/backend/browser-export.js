import { exportTiff } from "../tiff-export.js";
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
  const next = await session.render({
    ...request,
    comparison: false,
    purpose: "export",
    bitDepth: type === "image/tiff" ? 16 : 8,
  });
  if (!next) throw new DOMException("Export cancelled.", "AbortError");
  request.onProgress?.(`Encoding ${type.split("/")[1].toUpperCase()} export`);
  const blob =
    type === "image/tiff"
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
