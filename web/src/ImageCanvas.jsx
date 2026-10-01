import { usePhotoNavigation } from "./usePhotoNavigation.js";
import { useCallback, useEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import HistogramPanel from "./HistogramPanel.jsx";
import ViewportDetail from "./ViewportDetail.jsx";
import { useViewportDetail } from "./useViewportDetail.js";
import { useImageLayer } from "./useImageLayer.js";
import { visiblePhotoViewport } from "./viewport.js";
import CropOverlay from "./CropOverlay.jsx";
import { clamp } from "./color-controls.js";
import {
  MAX_ZOOM,
  anchoredPhotoZoom,
  centredPhotoZoom,
} from "./photo-navigation.js";

const FIT = Object.freeze({ zoom: 1, offset: [0, 0] });

export function ImageCanvas({
  result,
  detailSession,
  detailRequest,
  detailEnabled,
  onDetailError,
  onDetailBackend,
  original,
  sourceKey,
  photoView,
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
  sampling = false,
  onSample,
}) {
  const container = useRef(null),
    plane = useRef(null);
  // The view is the canvas's own: nothing else renders while the photograph moves. `latest` holds
  // the newest, ahead of the render that shows it once an animation frame. The toolbar, keys and
  // menus step it through `photoView`, which hears of every view shown.
  const [view, setView] = useState(FIT);
  const latest = useRef(FIT),
    frame = useRef(0),
    layout = useRef(null);
  const jump = useCallback((next) => {
    latest.current = next;
    setView(next);
  }, []);
  const show = useCallback((next) => {
    latest.current = next;
    if (frame.current) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = 0;
      // Rendered within this frame, so the host's image layer moves in the same frame as the page.
      flushSync(() => setView(latest.current));
    });
  }, []);
  useEffect(() => () => cancelAnimationFrame(frame.current), []);
  const [room, setRoom] = useState([1, 1]),
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
  useEffect(() => jump(FIT), [sourceKey, jump]);
  useEffect(
    () =>
      photoView.attach((zoom) => {
        const current = latest.current;
        const nextZoom = typeof zoom === "function" ? zoom(current.zoom) : zoom;
        jump(centredPhotoZoom({ ...current, nextZoom, ...layout.current }));
      }),
    [photoView, jump],
  );
  const width = result?.width || original?.naturalWidth || 1,
    height = result?.height || original?.naturalHeight || 1;
  const fit = Math.min(
    (room[0] - 48) / width,
    (room[1] - 48) / height,
    Math.max(1, (outputWidth || width) / width),
  );
  const displayWidth = Math.max(1, width * fit),
    displayHeight = Math.max(1, height * fit);
  layout.current = { display: [displayWidth, displayHeight], room };
  const { offset } = view;
  const viewport = visiblePhotoViewport({
    room,
    displayWidth,
    displayHeight,
    zoom: cropMode ? 1 : view.zoom,
    offset: cropMode ? [0, 0] : offset,
    framePlan: cropMode ? null : result?.framePlan,
    pixelRatio,
  });
  const detail = useViewportDetail({
    session: detailSession,
    request: detailRequest,
    viewport,
    enabled: detailEnabled,
    onError: onDetailError,
    onBackend: onDetailBackend,
  });
  // The host draws a presented photograph beneath the page; the page leaves it a hole.
  const presented = useImageLayer({
    container,
    plane,
    result,
    detail,
    compare,
  });
  const displayUrl = compare
    ? result?.originalUrl || original?.src
    : result?.url || original?.src;
  const nativeScale = displayWidth / Math.max(1, outputWidth || width);
  const readout = Math.round(nativeScale * (cropMode ? 1 : view.zoom) * 100);
  useEffect(() => {
    photoView.publish({ zoom: view.zoom, readout });
  }, [photoView, view.zoom, readout]);
  // Fit and the photograph's own pixels (at most the largest zoom), about `anchor`.
  const toggle = (anchor) => {
    const current = latest.current;
    const target = current.zoom === 1 ? clamp(1 / nativeScale, 1, MAX_ZOOM) : 1;
    jump({
      ...anchoredPhotoZoom({
        ...current,
        ...layout.current,
        anchor,
        scale: target / current.zoom,
      }),
      zoom: target,
    });
  };
  const navigation = usePhotoNavigation({
    container,
    sourceKey,
    cropMode,
    sampling,
    onSample,
    view: latest,
    show,
    toggle,
    display: [displayWidth, displayHeight],
    room,
    setCompare,
  });
  return (
    <div
      ref={container}
      className={`canvas-area ${cropMode ? "cropping" : ""} ${sampling ? "sampling" : ""}`}
      tabIndex={0}
      aria-label="Photo preview"
      onDoubleClick={(event) => {
        if (cropMode || event.target.closest(".histogram")) return;
        const box = event.currentTarget.getBoundingClientRect();
        toggle([
          event.clientX - box.left - box.width / 2,
          event.clientY - box.top - box.height / 2,
        ]);
      }}
      {...navigation}
    >
      {displayUrl && (
        <div
          ref={plane}
          className={`photo-plane ${result?.framePlan && !cropMode ? "framed" : ""}`}
          style={{
            width: displayWidth,
            height: displayHeight,
            transform: `translate(${cropMode ? 0 : offset[0]}px, ${cropMode ? 0 : offset[1]}px) scale(${cropMode ? 1 : view.zoom})`,
          }}
        >
          {presented ? (
            <div
              className="presented-photo"
              role="img"
              aria-label={compare ? "Original photo" : "Developed photo"}
            />
          ) : (
            <img
              src={displayUrl}
              alt={compare ? "Original photo" : "Developed photo"}
              draggable="false"
            />
          )}
          <ViewportDetail detail={detail} compare={compare} />
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
