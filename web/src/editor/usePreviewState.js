import { useState, useMemo } from "react";
import { fullCrop } from "../editor-state.js";
import { usePreviewQuality } from "../usePreviewQuality.js";
import { useLensCatalogue } from "../useLensCatalogue.js";
import { fixedStockSettings } from "../stock-settings.js";
import { previewBudget } from "../preview-budget.js";
import { negativeViewEdit } from "../negative-view.js";
import { useAppSetting } from "../app-settings.js";
import { usePlaying } from "../video-player/usePlaying.js";
import { playbackEdge } from "../video-player/playback-quality.js";
export default function usePreviewState({
  backend,
  panel,
  inspectorOpen,
  edit,
  activeId,
  stage,
  difference,
  showMask,
  videoTime,
  zoom,
  history,
  active,
  stocks,
  retry,
  error,
  libraryError,
  showNegative,
}) {
  const cropMode = panel === "crop" && inspectorOpen;
  const [zoomReadout, setZoomReadout] = useState(100);
  const viewed = negativeViewEdit(
    edit,
    stocks.find((stock) => stock.id === edit.stock),
    showNegative,
  );
  const previewEditJSON = JSON.stringify(
    cropMode
      ? {
          ...viewed,
          crop: fullCrop(),
          ratio: "free",
        }
      : viewed,
  );
  const [viewerMoving, setViewerMoving] = useState(false);
  const [detailBackend, setDetailBackend] = useState(null);
  const editInteractionKey = JSON.stringify([
    activeId,
    previewEditJSON,
    stage,
    difference,
    cropMode,
    showMask,
    videoTime,
  ]);
  const interactionKey = JSON.stringify([editInteractionKey, zoom]);
  const budget = previewBudget(backend);
  const interacting = usePreviewQuality(
    interactionKey,
    !!history.group || viewerMoving,
    budget.settleMs,
  );
  const previewInteracting = usePreviewQuality(
    editInteractionKey,
    !!history.group,
    budget.settleMs,
  );
  const [interactiveEdge, setInteractiveEdge] = useState(
    budget.initialInteractiveEdge,
  );
  // A playing movie develops at the chosen Playback Quality where the backend offers one, as
  // the Mac app plays; paused, at full detail.
  const playing = usePlaying();
  const playbackQuality = useAppSetting("videoPlaybackQuality");
  const playingEdge =
    backend.playbackQuality && active?.image.video && playing
      ? playbackEdge(playbackQuality)
      : null;
  const previewEdge = Math.min(
    Math.max(
      active?.image.naturalWidth || 1600,
      active?.image.naturalHeight || 1600,
    ),
    playingEdge ?? (previewInteracting ? interactiveEdge : 1600),
  );
  const lensCatalogue = useLensCatalogue();
  const previewKey = JSON.stringify([
    lensCatalogue.revision,
    activeId,
    active?.image.video ? videoTime : null,
    previewEditJSON,
    stage,
    difference,
    cropMode,
    previewEdge,
    showMask,
  ]);
  const previewEdit = useMemo(
    () => JSON.parse(previewEditJSON),
    [previewEditJSON],
  );
  const detailRequest = useMemo(
    () =>
      active
        ? {
            image: active.image,
            videoTime,
            edit: previewEdit,
            stock: previewEdit.stock || stocks[0]?.id || "normal",
            stage,
            difference,
            cropMode,
            showMask,
          }
        : null,
    [
      active,
      videoTime,
      previewEdit,
      stocks,
      stage,
      difference,
      cropMode,
      showMask,
      retry,
    ],
  );
  const selectedStock = stocks.find((stock) => stock.id === edit.stock);
  const fixedSettings = fixedStockSettings(selectedStock);
  const stockId = edit.stock || stocks[0]?.id || "normal";
  const visibleError = error || libraryError;
  return {
    cropMode,
    zoomReadout,
    setZoomReadout,
    previewEditJSON,
    viewerMoving,
    setViewerMoving,
    detailBackend,
    setDetailBackend,
    editInteractionKey,
    interactionKey,
    interacting,
    previewInteracting,
    interactiveEdge,
    setInteractiveEdge,
    previewEdge,
    lensCatalogue,
    previewKey,
    previewEdit,
    detailRequest,
    selectedStock,
    fixedSettings,
    stockId,
    visibleError,
  };
}
