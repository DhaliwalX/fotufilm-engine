import { cleanName } from "./file-download.js";
export default function useExportActions({
  backend,
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
  exportMetadata,
  exportHDR,
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
      const saved = await backend.exportVideo({
        image: active.image,
        edit,
        stock: stockId,
        session,
        filename,
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
      const extension =
        exportType === "image/jpeg" ? "jpg" : exportType.split("/")[1];
      await backend.exportImage({
        session,
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: exportSize === "full" ? Infinity : Number(exportSize),
        type: exportType,
        quality: quality / 100,
        metadata: exportMetadata,
        hdr: exportHDR,
        onProgress: setStatus,
        filename: `${cleanName(active.name)}-${edit.stock || "normal"}${edit.medium ? `-${edit.medium}` : ""}.${extension}`,
      });
      setDialog(null);
    } catch (e) {
      // Dismissing a native save panel is a choice, not a failure.
      if (e.name !== "AbortError") setError(e.message);
    } finally {
      setExporting(false);
      setStatus(null);
    }
  }
  // Only a host with a pasteboard of its own copies the developed picture (Copy Photo).
  async function copyPhoto() {
    if (!backend.copyImage || !active || active.image.video || !session || exporting)
      return;
    setError(null);
    setStatus("Copying the photo");
    try {
      await backend.copyImage({
        session,
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: Infinity,
      });
    } catch (e) {
      setError(e.message);
    } finally {
      setStatus(null);
    }
  }
  return {
    exportClip,
    exportImage,
    copyPhoto,
  };
}
