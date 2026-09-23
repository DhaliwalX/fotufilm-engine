import { useRef, useEffect, useCallback, useState } from "react";
import { PreviewQueue } from "../preview-queue.js";
export default function useRendererLifecycle({
  backend,
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
  imageResources,
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
  const [startupProgress, setStartupProgress] = useState({
    value: 0,
    label: "Loading image engine",
    done: false,
  });
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
    const renderer = backend.createSession();
    renderer.onRendererReady = () => {
      if (alive.current) setRetry((value) => value + 1);
    };
    alive.current = true;
    previewQueue.current = new PreviewQueue((text) => {
      if (alive.current && !currentPreview.current?.exporting) setStatus(text);
    });
    setSession(renderer);
    let cancelled = false;
    // Defer one task so React's development remount does not start two engines.
    const startup = setTimeout(() => {
      Promise.resolve()
        .then(() =>
          backend.prepare(renderer, (state) => {
            if (!cancelled) setStartupProgress(state);
          }),
        )
        .catch((error) => {
          if (cancelled) return;
          setLibraryError(error.message);
          setStartupProgress({
            value: 100,
            label: "Image engine unavailable",
            done: true,
          });
        });
    }, 0);
    return () => {
      cancelled = true;
      clearTimeout(startup);
      alive.current = false;
      previewQueue.current.close();
      renderer.dispose();
      videoExportController.current?.abort();
      videoDownloadRef.current?.dispose();
      for (const image of imageResources.current) backend.releaseImage(image);
      imageResources.current.clear();
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
    backend
      .loadStocks()
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
    startupProgress,
    alive,
    previewQueue,
    lastRenderedPreview,
    currentPreview,
    replaceResult,
  };
}
