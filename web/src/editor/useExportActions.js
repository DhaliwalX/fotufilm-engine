import { exportMaxEdge } from "../export-sizes.js";
import { cleanName } from "./file-download.js";
import { setAppSetting } from "../app-settings.js";
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
  // The picture's upright size, which a fractional export size is a fraction of.
  const upright = () => {
    const { naturalWidth: w = 0, naturalHeight: h = 0 } = active?.image ?? {};
    return edit.rotation % 2 ? [h, w] : [w, h];
  };
  async function exportClip() {
    if (!active?.image.video || !session || exporting) return;
    const controller = new AbortController();
    videoExportController.current = controller;
    setExporting(true);
    setError(null);
    setStatus("Choose an export destination");
    try {
      // A native format names its container, which is not always its id (HEVC, ProRes).
      const extension =
        backend.videoExportTypes?.find(({ id }) => id === videoFormat)?.extension ?? videoFormat;
      const filename = `${cleanName(active.name)}-${edit.stock || "normal"}.${extension}`;
      const saved = await backend.exportVideo({
        image: active.image,
        edit,
        stock: stockId,
        session,
        filename,
        format: videoFormat,
        quality: videoQuality,
        maxEdge: exportMaxEdge(exportSize, ...upright()),
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
      setAppSetting("lastVideoExport", {
        format: videoFormat,
        quality: videoQuality,
        size: exportSize,
      });
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
    // Cancel reaches the export where the backend stops on a signal (exportImageCancels).
    const controller = new AbortController();
    videoExportController.current = controller;
    setExporting(true);
    setError(null);
    try {
      if (exportType === "original") {
        // The camera RAW itself: no render, no size, no settings to remember.
        await backend.exportOriginal(active.image);
        setDialog(null);
        return;
      }
      const extension =
        exportType === "image/jpeg" ? "jpg" : exportType.split("/")[1];
      await backend.exportImage({
        session,
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: exportMaxEdge(exportSize, ...upright()),
        type: exportType,
        quality: quality / 100,
        metadata: exportMetadata,
        hdr: exportHDR,
        signal: controller.signal,
        onProgress: setStatus,
        filename: `${cleanName(active.name)}-${edit.stock || "normal"}${edit.medium ? `-${edit.medium}` : ""}.${extension}`,
      });
      setAppSetting("lastPhotoExport", {
        type: exportType,
        size: exportSize,
        quality,
        metadata: exportMetadata,
      });
      setDialog(null);
    } catch (e) {
      // Dismissing a native save panel is a choice, not a failure.
      if (e.name !== "AbortError") setError(e.message);
    } finally {
      videoExportController.current = null;
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
