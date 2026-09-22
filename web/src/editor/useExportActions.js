import { cleanName, download } from "./file-download.js";
import { createVideoDestination, exportVideo } from "../video-export.js";
import { exportTiff } from "../tiff-export.js";
import { canvasBlob } from "../geometry.js";
export default function useExportActions({
  active,
  session,
  exporting,
  videoExportController,
  setExporting,
  setError,
  setStatus,
  edit,
  videoFormat,
  stockId,
  videoQuality,
  exportSize,
  alive,
  videoDownloadRef,
  setVideoDownload,
  setDialog,
  exportType,
  quality,
}) {
  async function exportClip() {
    if (!active?.image.video || !session || exporting) return;
    const controller = new AbortController();
    videoExportController.current = controller;
    setExporting(true);
    setError(null);
    setStatus("Choose an export destination");
    try {
      const filename = `${cleanName(active.name)}-${edit.stock || "normal"}.${videoFormat}`;
      const destination = await createVideoDestination(filename);
      const saved = await exportVideo({
        image: active.image,
        edit,
        stock: stockId,
        session,
        destination,
        format: videoFormat,
        quality: videoQuality,
        maxEdge: exportSize === "full" ? Infinity : Number(exportSize),
        signal: controller.signal,
        onProgress: ({ progress, frames, finalizing }) =>
          setStatus(
            finalizing
              ? "Finalizing video file"
              : `Exporting video · ${Math.floor(progress * 100)}% · ${frames} frames`,
          ),
      });
      if (!alive.current) {
        await saved.dispose();
        return;
      }
      await videoDownloadRef.current?.dispose();
      videoDownloadRef.current = saved;
      setVideoDownload(saved);
      setDialog(null);
    } catch (error) {
      if (
        error.name !== "AbortError" &&
        error.name !== "ConversionCanceledError" &&
        alive.current
      )
        setError(error.message);
    } finally {
      videoExportController.current = null;
      if (alive.current) {
        setExporting(false);
        setStatus(null);
      }
    }
  }
  async function exportImage() {
    if (!active || !session || !stockId || exporting) return;
    setExporting(true);
    setError(null);
    try {
      const next = await session.render({
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: exportSize === "full" ? Infinity : Number(exportSize),
        comparison: false,
        purpose: "export",
        bitDepth: exportType === "image/tiff" ? 16 : 8,
        onProgress: setStatus,
      });
      if (!next) throw new Error("Export was cancelled.");
      setStatus(`Encoding ${exportType.split("/")[1].toUpperCase()} export`);
      const blob =
        exportType === "image/tiff"
          ? await exportTiff(next)
          : exportType === "image/png"
            ? next.blob
            : await canvasBlob(next.canvas, exportType, quality / 100);
      const extension =
        exportType === "image/jpeg" ? "jpg" : exportType.split("/")[1];
      download(
        blob,
        `${cleanName(active.name)}-${edit.stock || "normal"}${edit.medium ? `-${edit.medium}` : ""}.${extension}`,
      );
      setDialog(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setExporting(false);
      setStatus(null);
    }
  }
  return {
    exportClip,
    exportImage,
  };
}
