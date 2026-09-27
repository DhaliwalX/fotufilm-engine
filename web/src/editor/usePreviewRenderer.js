import { useEffect } from "react";
import { previewLabel } from "../preview-queue.js";
import { previewBudget } from "../preview-budget.js";
export default function usePreviewRenderer({
  backend,
  active,
  stockId,
  session,
  exporting,
  alive,
  currentPreview,
  videoTime,
  previewEdit,
  showMask,
  previewEdge,
  stage,
  difference,
  cropMode,
  previewInteracting,
  previewKey,
  stocks,
  stages,
  lastRenderedPreview,
  previewQueue,
  setInteractiveEdge,
  urls,
  replaceResult,
  setError,
  setStatus,
  retry,
}) {
  useEffect(() => {
    if (!active || !stockId || !session || exporting) return;
    const currentFile = () =>
      alive.current && currentPreview.current?.activeId === active.id;
    const request = {
      image: active.image,
      videoTime,
      interactive: previewInteracting,
      edit: previewEdit,
      showMask,
      stock: stockId,
      maxEdge: previewEdge,
      stage,
      difference,
      cropMode,
      // A host that draws the photograph itself shows the preview without a picture crossing.
      present: backend.imageLayer ? "preview" : undefined,
      stale: () =>
        !currentFile() ||
        currentPreview.current.exporting ||
        currentPreview.current.cropMode !== cropMode ||
        (!previewInteracting &&
          (currentPreview.current.previewInteracting ||
            currentPreview.current.key !== previewKey)),
    };
    const frame = requestAnimationFrame(() => {
      const stock = stocks.find((item) => item.id === previewEdit.stock);
      const queued = {
        fileId: active.id,
        filename: active.name,
        edit: previewEdit,
        stockName: stock?.name,
        mediumName: stock?.media.find(
          (medium) => medium.id === previewEdit.medium,
        )?.name,
        edge: previewEdge,
        cropMode,
        stage,
        difference,
        stageLabel: stages[stage]?.label,
      };
      const label = previewLabel(queued, lastRenderedPreview.current);
      previewQueue.current
        .submit(
          (onProgress) =>
            session.render({
              ...request,
              onProgress,
            }),
          label,
        )
        .then((next) => {
          if (
            !next ||
            !currentFile() ||
            currentPreview.current.exporting ||
            currentPreview.current.cropMode !== cropMode ||
            request.stale()
          )
            return;
          if (previewInteracting) {
            const budget = previewBudget(backend);
            if (next.renderMilliseconds > 65)
              setInteractiveEdge((edge) =>
                Math.max(budget.minInteractiveEdge, Math.round(edge * 0.8)),
              );
            else if (next.renderMilliseconds < 25)
              setInteractiveEdge((edge) =>
                Math.min(budget.maxInteractiveEdge, Math.round(edge * 1.1)),
              );
          }
          // A presented preview is on screen already; the page only places it.
          const url = next.presented ? undefined : URL.createObjectURL(next.blob),
            originalUrl = next.presented ? undefined : URL.createObjectURL(next.original);
          if (url) urls.current.add(url);
          if (originalUrl) urls.current.add(originalUrl);
          replaceResult({
            ...next,
            url,
            originalUrl,
            key: previewKey,
            fileId: active.id,
            stock: previewEdit.stock,
            stage,
          });
          lastRenderedPreview.current = queued;
          setError(null);
        })
        .catch((error) => {
          if (currentFile()) {
            setError(error.message);
            if (!previewQueue.current.running) setStatus(null);
          }
        });
    });
    return () => cancelAnimationFrame(frame);
  }, [
    active,
    videoTime,
    previewEdit,
    previewEdge,
    previewInteracting,
    previewKey,
    stockId,
    session,
    stage,
    difference,
    cropMode,
    exporting,
    retry,
    replaceResult,
  ]);
}
