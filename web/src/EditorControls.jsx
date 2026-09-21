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

export function Histogram({ canvas, onClose }) {
  const ref = useRef(null);
  const [offset, setOffset] = useState([0, 0]);
  const drag = useRef(null);
  useEffect(() => {
    if (!canvas) return;
    const reduced = document.createElement("canvas");
    reduced.width = 128;
    reduced.height = 128;
    const ctx = reduced.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(canvas, 0, 0, 128, 128);
    const pixels = ctx.getImageData(0, 0, 128, 128).data;
    const bins = Array.from({ length: 3 }, () => Array(64).fill(0));
    for (let i = 0; i < pixels.length; i += 4)
      for (let c = 0; c < 3; c++) bins[c][pixels[i + c] >> 2]++;
    const plot = ref.current.getContext("2d"),
      width = 192,
      height = 72;
    plot.clearRect(0, 0, width, height);
    const peak = Math.max(1, ...bins.flat());
    bins.forEach((channel, c) => {
      plot.beginPath();
      plot.moveTo(0, height);
      channel.forEach((n, x) =>
        plot.lineTo((x * width) / 63, height - (n / peak) * (height - 3)),
      );
      plot.lineTo(width, height);
      plot.closePath();
      plot.fillStyle = ["#f1787890", "#78c99b90", "#79a7ed90"][c];
      plot.fill();
    });
  }, [canvas]);
  return (
    <div
      className="histogram"
      style={{
        transform: `translate(${offset[0]}px, ${offset[1]}px)`,
      }}
    >
      <div
        className="histogram-header"
        onPointerDown={(e) => {
          if (e.target.closest("button")) return;
          e.currentTarget.setPointerCapture(e.pointerId);
          drag.current = [e.clientX, e.clientY, ...offset];
        }}
        onPointerMove={(e) => {
          if (drag.current) {
            const room = e.currentTarget
              .closest(".canvas-area")
              .getBoundingClientRect();
            setOffset([
              clamp(
                drag.current[2] + e.clientX - drag.current[0],
                0,
                Math.max(0, room.width - 224),
              ),
              clamp(
                drag.current[3] + e.clientY - drag.current[1],
                0,
                Math.max(0, room.height - 150),
              ),
            ]);
          }
        }}
        onPointerUp={() => {
          drag.current = null;
        }}
        onPointerCancel={() => {
          drag.current = null;
        }}
      >
        <span>RGB histogram</span>
        <button aria-label="Close histogram" onClick={onClose}>
          ×
        </button>
      </div>
      <canvas
        ref={ref}
        width="192"
        height="72"
        aria-label="Red, green and blue tonal distribution"
      />
      <div className="histogram-scale">
        <span>0</span>
        <span>255</span>
      </div>
    </div>
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
      {showHistogram && result && (
        <Histogram canvas={result.canvas} onClose={showHistogram} />
      )}
    </div>
  );
}
