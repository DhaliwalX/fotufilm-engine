import { useRef, useEffect, useCallback } from "react";
import { RenderSession, loadStockIndex } from "../render-session.js";
import { PreviewQueue } from "../preview-queue.js";
export default function useRendererLifecycle({
  activeId,
  previewKey,
  exporting,
  cropMode,
  interacting,
  previewInteracting,
  interactionKey,
  setRetry,
  setStatus,
  setSession,
  videoExportController,
  videoDownloadRef,
  clips,
  importController,
  loadGeneration,
  urls,
  setLibraryError,
  setStocks,
  retry,
  histories,
  history,
  setResult,
}) {
  const alive = useRef(false);
  const previewQueue = useRef(null);
  const lastRenderedPreview = useRef(null);
  const currentPreview = useRef(null);
  currentPreview.current = {
    activeId,
    key: previewKey,
    exporting,
    cropMode,
    interacting,
    previewInteracting,
    interactionKey,
  };
  useEffect(() => {
    const renderer = new RenderSession();
    renderer.onRendererReady = () => {
      if (alive.current) setRetry((value) => value + 1);
    };
    alive.current = true;
    previewQueue.current = new PreviewQueue((text) => {
      if (alive.current && !currentPreview.current?.exporting) setStatus(text);
    });
    setSession(renderer);
    return () => {
      alive.current = false;
      previewQueue.current.close();
      renderer.dispose();
      videoExportController.current?.abort();
      videoDownloadRef.current?.dispose();
      for (const clip of clips.current) clip.dispose();
      clips.current.clear();
      importController.current?.abort();
      loadGeneration.current++;
      for (const url of urls.current) URL.revokeObjectURL(url);
      urls.current.clear();
    };
  }, []);
  useEffect(() => {
    let cancelled = false;
    setLibraryError(null);
    setStatus("Loading films");
    loadStockIndex()
      .then((index) => {
        if (!cancelled) {
          setStocks(index);
          setStatus(null);
        }
      })
      .catch((e) => {
        if (!cancelled) {
          setLibraryError(e.message);
          setStatus(null);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [retry]);
  useEffect(() => {
    if (activeId) histories.current.set(activeId, history);
  }, [history, activeId]);
  const replaceResult = useCallback((next) => {
    setResult((previous) => {
      for (const url of [previous?.url, previous?.originalUrl])
        if (url) {
          URL.revokeObjectURL(url);
          urls.current.delete(url);
        }
      return next;
    });
  }, []);
  return {
    alive,
    previewQueue,
    lastRenderedPreview,
    currentPreview,
    replaceResult,
  };
}
