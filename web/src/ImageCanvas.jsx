import { usePhotoNavigation } from "./usePhotoNavigation.js";
import { useEffect, useRef, useState } from "react";
import HistogramPanel from "./HistogramPanel.jsx";
import ViewportDetail from "./ViewportDetail.jsx";
import { visiblePhotoViewport } from "./viewport.js";
import CropOverlay from "./CropOverlay.jsx";
import { clamp } from "./color-controls.js";
export function ImageCanvas({
  result,
  detailSession,
  detailRequest,
  detailEnabled,
  onDetailError,
  onDetailBackend,
  original,
  sourceKey,
  zoom,
  setZoom,
  compare,
  setCompare,
  cropMode,
  crop,
  cropShape,
  cropRatio,
  cropIdentity,
  onCrop,
  onEnd,
  showHistogram,
  outputWidth,
  onZoomReadout,
  onInteraction,
  sampling = false,
  onSample,
}) {
  const container = useRef(null);
  const [offset, setOffset] = useState([0, 0]),
    [room, setRoom] = useState([1, 1]),
    [pixelRatio, setPixelRatio] = useState(() => window.devicePixelRatio || 1);
  useEffect(() => {
    let query;
    const update = () => {
      const ratio = window.devicePixelRatio || 1;
      setPixelRatio(ratio);
      query?.removeEventListener("change", update);
      query = window.matchMedia(`(resolution: ${ratio}dppx)`);
      query.addEventListener("change", update);
    };
    update();
    return () => query?.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    const observer = new ResizeObserver(([entry]) =>
      setRoom([entry.contentRect.width, entry.contentRect.height]),
    );
    observer.observe(container.current);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    setOffset([0, 0]);
    setZoom(1);
  }, [sourceKey, setZoom]);
  useEffect(() => {
    if (zoom === 1) setOffset([0, 0]);
  }, [zoom]);
  const width = result?.width || original?.naturalWidth || 1,
    height = result?.height || original?.naturalHeight || 1;
  const fit = Math.min(
    (room[0] - 48) / width,
    (room[1] - 48) / height,
    Math.max(1, (outputWidth || width) / width),
  );
  const displayWidth = Math.max(1, width * fit),
    displayHeight = Math.max(1, height * fit);
  const viewport = visiblePhotoViewport({
    room,
    displayWidth,
    displayHeight,
    zoom: cropMode ? 1 : zoom,
    offset: cropMode ? [0, 0] : offset,
    framePlan: cropMode ? null : result?.framePlan,
    pixelRatio,
  });
  const displayUrl = compare
    ? result?.originalUrl || original?.src
    : result?.url || original?.src;
  const nativeScale = displayWidth / Math.max(1, outputWidth || width);
  useEffect(() => {
    onZoomReadout?.(Math.round(nativeScale * (cropMode ? 1 : zoom) * 100));
  }, [nativeScale, cropMode, zoom, onZoomReadout]);
  const navigation = usePhotoNavigation({
    container,
    sourceKey,
    cropMode,
    sampling,
    onSample,
    zoom,
    setZoom,
    offset,
    setOffset,
    display: [displayWidth, displayHeight],
    room,
    setCompare,
    onInteraction,
  });
  return (
    <div
      ref={container}
      className={`canvas-area ${cropMode ? "cropping" : ""} ${sampling ? "sampling" : ""}`}
      tabIndex={0}
      aria-label="Photo preview"
      onDoubleClick={(event) => {
        if (!cropMode && !event.target.closest(".histogram"))
          setZoom((z) => (z === 1 ? clamp(1 / nativeScale, 1, 8) : 1));
      }}
      {...navigation}
    >
      {displayUrl && (
        <div
          className={`photo-plane ${result?.framePlan && !cropMode ? "framed" : ""}`}
          style={{
            width: displayWidth,
            height: displayHeight,
            transform: `translate(${cropMode ? 0 : offset[0]}px, ${cropMode ? 0 : offset[1]}px) scale(${cropMode ? 1 : zoom})`,
          }}
        >
          <img
            src={displayUrl}
            alt={compare ? "Original photo" : "Developed photo"}
            draggable="false"
          />
          <ViewportDetail
            session={detailSession}
            request={detailRequest}
            viewport={viewport}
            enabled={detailEnabled}
            compare={compare}
            onError={onDetailError}
            onBackend={onDetailBackend}
          />
          {cropMode && (
            <CropOverlay
              crop={crop}
              shape={cropShape}
              ratio={cropRatio}
              sourceKey={cropIdentity || sourceKey}
              onChange={onCrop}
              onEnd={onEnd}
            />
          )}
        </div>
      )}
      {compare && <span className="original-badge">Original</span>}
      <HistogramPanel
        result={result}
        open={!!showHistogram && !!result}
        onClose={showHistogram}
        container={container}
      />
    </div>
  );
}
