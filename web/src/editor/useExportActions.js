import { exportBasis, exportMaxEdge } from "../export-sizes.js";
import { outputSize } from "../geometry.js";
import { cleanName } from "./file-download.js";
import { appSetting, setAppSetting } from "../app-settings.js";
import { isVideoFile } from "../media-types.js";
import { sourcePath } from "./useDocumentActions.js";

// A still's file name: the photograph's, its film and its print medium.
const stillFilename = (name, edit, type) =>
  `${cleanName(name)}-${edit.stock || "normal"}${edit.medium ? `-${edit.medium}` : ""}.${
    type === "image/jpeg" ? "jpg" : type.split("/")[1]
  }`;

// Whether a document is a movie, which Export All leaves out: an open one says so, one not
// opened yet by its file.
export const isMovieDocument = (doc) =>
  doc.image
    ? !!doc.image.video
    : isVideoFile({ type: doc.source?.file?.type ?? "", name: doc.name ?? "" });

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
  savedExportRef,
  setSavedExport,
  setDialog,
  exportType,
  quality,
  exportMetadata,
  exportHDR,
  files,
  stocks,
  documentEdits,
}) {
  // Shows what an export saved, letting the last one go. A backend that saves by download
  // answers nothing for a still.
  const showSaved = async (saved) => {
    if (!saved?.filename) return;
    await savedExportRef.current?.dispose?.();
    savedExportRef.current = saved;
    setSavedExport(saved);
  };
  // The long edge an export size asks for, of the picture this backend measures: the upright
  // one, or its crop.
  const maxEdge = () => {
    const { naturalWidth: w = 0, naturalHeight: h = 0 } = active?.image ?? {};
    const [width, height] = edit.rotation % 2 ? [h, w] : [w, h];
    return exportMaxEdge(exportSize, ...exportBasis(width, height,
      outputSize(edit.crop, width, height), backend.longEdgeOfCrop === true));
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
        bitrate: appSetting("videoBitrate"),
        videoProcessing: appSetting("videoProcessing"),
        maxEdge: maxEdge(),
        hdr: appSetting("videoHDR") === true,
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
        bitrate: appSetting("videoBitrate"),
        frameRate: edit.video.frameRate,
        ...(backend.videoProcessing ? { processing: appSetting("videoProcessing") } : {}),
        size: exportSize,
      });
      await showSaved(saved);
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
        await showSaved(await backend.exportOriginal(active.image));
        setDialog(null);
        return;
      }
      const saved = await backend.exportImage({
        session,
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: maxEdge(),
        type: exportType,
        quality: quality / 100,
        metadata: exportMetadata,
        hdr: exportHDR,
        signal: controller.signal,
        onProgress: setStatus,
        filename: stillFilename(active.name, edit, exportType),
      });
      await showSaved(saved);
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
  // Export All: every photograph in the strip, each with its own edit, into one folder the host
  // asks for. Photographs not opened yet are decoded by the host as the export reaches them.
  async function exportAll() {
    if (!backend.exportImages || !session || exporting) return;
    const stills = files.filter((doc) => !isMovieDocument(doc));
    if (!stills.length) return;
    const controller = new AbortController();
    videoExportController.current = controller;
    setExporting(true);
    setError(null);
    setStatus("Preparing export");
    // Files the host cannot read itself are decoded here, and let go afterwards.
    const decoded = [];
    try {
      const edits = await documentEdits(stills);
      const items = [];
      for (const [index, doc] of stills.entries()) {
        const itemEdit = edits[index];
        let image = doc.image,
          path = null;
        if (doc.waiting) {
          path = sourcePath(doc);
          if (!path) {
            ({ image } = await backend.importMedia(doc.source.file, {
              signal: controller.signal,
            }));
            decoded.push(image);
          }
        }
        items.push({
          image: path ? undefined : image,
          path,
          name: doc.name,
          filename: stillFilename(doc.name, itemEdit, exportType),
          edit: itemEdit,
          stock: itemEdit.stock || stocks[0]?.id || "normal",
        });
      }
      const result = await backend.exportImages({
        items,
        size: exportSize,
        type: exportType,
        quality: quality / 100,
        metadata: exportMetadata,
        hdr: exportHDR,
        signal: controller.signal,
        onProgress: ({ done, total, name, current }) =>
          setStatus(name ? `Exporting ${name} · ${current} of ${total}` : `Exported ${done} of ${total}`),
      });
      setAppSetting("lastPhotoExport", {
        type: exportType,
        size: exportSize,
        quality,
        metadata: exportMetadata,
      });
      if (result.written.length)
        await showSaved({
          filename: `${result.written.length} photos`,
          path: result.written[0].path,
          count: result.written.length,
          directory: result.directory,
        });
      const problems = [
        ...result.failed.map(({ name, error }) => `${name}: ${error}`),
        ...(result.reduced.length
          ? [`Exported smaller to stay within this device’s safe memory limit: ${result.reduced.join(", ")}.`]
          : []),
      ];
      if (problems.length) setError(problems.join(" "));
      setDialog(null);
    } catch (e) {
      if (e.name !== "AbortError") setError(e.message);
    } finally {
      decoded.forEach((image) => backend.releaseImage(image));
      videoExportController.current = null;
      if (alive.current) {
        setExporting(false);
        setStatus(null);
      }
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
    exportAll,
    copyPhoto,
  };
}
