import HistogramPanel from "./HistogramPanel.jsx";
import ViewportDetail from "./ViewportDetail.jsx";
import { visiblePhotoViewport } from "./viewport.js";
import CropOverlay from "./CropOverlay.jsx";
import { Button } from "@astryxdesign/core/Button";
import { Slider } from "@astryxdesign/core/Slider";
import { NumberInput } from "@astryxdesign/core/NumberInput";
import { useEffect, useRef, useState } from "react";
import { SLIDERS } from "./editor-state.js";
import { clamp } from "./color-controls.js";
import { Icon } from "./icons.jsx";

export { Icon } from "./icons.jsx";

export function ToolButton({
  icon,
  label,
  active,
  children,
  disabled,
  ...props
}) {
  return (
    <Button
      label={label}
      variant="ghost"
      size="sm"
      icon={<Icon name={icon} />}
      isIconOnly={!children}
      isDisabled={disabled}
      className={`tool-button ${active ? "active" : ""}`}
      title={label}
      aria-pressed={active}
      {...props}
    >
      {children}
    </Button>
  );
}
export function Section({ title, children, open = true }) {
  return (
    <details className="inspector-section" open={open}>
      <summary>{title}</summary>
      <div className="section-content">{children}</div>
    </details>
  );
}
export function Adjustment({
  slider,
  value,
  onChange,
  onEnd,
  disabled = false,
}) {
  const accessibleLabel = slider.key.startsWith("grade")
    ? `${slider.group} ${slider.label}`
    : slider.label;
  const temperature = slider.key === "temperature";
  const rangeValue = temperature ? 1e6 / value : value;
  return (
    <div className="adjustment">
      <div className="adjustment-label">
        <span>{slider.label}</span>
        <div className="number-field">
          <NumberInput
            label={`${accessibleLabel} value`}
            isLabelHidden
            isDisabled={disabled}
            size="sm"
            width={88}
            hasNumberSteppers={false}
            isWheelEnabled={false}
            units={slider.unit}
            value={Number(value.toFixed(3))}
            min={slider.min}
            max={slider.max}
            step={slider.step}
            onChange={(next) => onChange(clamp(next, slider.min, slider.max))}
            onBlur={onEnd}
          />
        </div>
      </div>
      <Slider
        label={accessibleLabel}
        isLabelHidden
        isDisabled={disabled}
        valueDisplay="none"
        min={temperature ? 1e6 / slider.max : slider.min}
        max={temperature ? 1e6 / slider.min : slider.max}
        step={temperature ? 0.1 : slider.step}
        value={rangeValue}
        formatValue={
          temperature ? (v) => `${Math.round(1e6 / v)} K` : undefined
        }
        onChange={(next) =>
          onChange(temperature ? Math.round(1e6 / next) : next)
        }
        onChangeEnd={onEnd}
        onBlur={onEnd}
        onDoubleClick={() => {
          onChange(slider.def);
          onEnd?.();
        }}
      />
    </div>
  );
}
export function Adjustments({
  group,
  params,
  onChange,
  onEnd,
  disabled,
  hasFilm = true,
}) {
  return SLIDERS.filter(
    (s) => s.group === group && (hasFilm || s.availability !== "film"),
  ).map((slider) => (
    <Adjustment
      key={slider.key}
      slider={slider}
      disabled={disabled}
      value={params[slider.key]}
      onChange={(value) => onChange(slider.key, value)}
      onEnd={onEnd}
    />
  ));
}
export function Modal({ title, children, onClose, className }) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current,
      before = document.activeElement;
    dialog.showModal();
    return () => {
      dialog.close();
      before?.focus();
    };
  }, []);
  return (
    <dialog
      ref={ref}
      className={className}
      aria-label={title}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="dialog-header">
        <h2>{title}</h2>
        <ToolButton icon="close" label="Close" onClick={onClose} />
      </div>
      {children}
    </dialog>
  );
}

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
  const container = useRef(null),
    drag = useRef(null);
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
  useEffect(() => {
    const surface = container.current;
    const wheel = (event) => {
      if (cropMode || event.target.closest(".histogram")) return;
      event.preventDefault();
      setZoom((z) => clamp(z * (event.deltaY > 0 ? 0.9 : 1.1), 1, 8));
    };
    surface.addEventListener("wheel", wheel, { passive: false });
    return () => surface.removeEventListener("wheel", wheel);
  }, [cropMode, setZoom]);
  function begin(e) {
    if (e.button !== 0 || cropMode || e.target.closest(".histogram")) return;
    if (sampling) {
      const plane = e.target.closest(".photo-plane");
      if (plane) {
        const bounds = plane.getBoundingClientRect();
        onSample?.([
          (e.clientX - bounds.left) / bounds.width,
          (e.clientY - bounds.top) / bounds.height,
        ]);
      }
      return;
    }
    e.currentTarget.setPointerCapture(e.pointerId);
    if (zoom === 1) setCompare(true);
    else {
      drag.current = [e.clientX, e.clientY, ...offset];
      onInteraction?.(true);
    }
  }
  function end() {
    drag.current = null;
    onInteraction?.(false);
    setCompare(false);
  }
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
      onPointerDown={begin}
      onPointerMove={(e) => {
        if (drag.current)
          setOffset([
            clamp(
              drag.current[2] + e.clientX - drag.current[0],
              (-displayWidth * (zoom - 1)) / 2,
              (displayWidth * (zoom - 1)) / 2,
            ),
            clamp(
              drag.current[3] + e.clientY - drag.current[1],
              (-displayHeight * (zoom - 1)) / 2,
              (displayHeight * (zoom - 1)) / 2,
            ),
          ]);
      }}
      onPointerUp={end}
      onPointerCancel={end}
      onLostPointerCapture={end}
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
      <HistogramPanel result={result} open={!!showHistogram && !!result} onClose={showHistogram} container={container} />
    </div>
  );
}
