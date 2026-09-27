import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { colorContext } from "../canvas-color.js";
import { clampArea, orientArea } from "./recipe.js";
import { cropDrag, hitCrop } from "./crop-drag.js";

// The session's picture: each print drawn as it arrives, fitted to the stage, with the crop
// frame over the uncropped print (`mode` "crop") or a sampling rectangle over the whole negative
// (`mode` "border"). Reports the long edge a preview needs at this size and pixel density.
export default function NegativeScanCanvas({
  frame,
  recipe,
  mode,
  aspect,
  onCrop,
  onBorder,
  onSize,
  placeholder,
}) {
  const stage = useRef(null);
  const canvas = useRef(null);
  const [box, setBox] = useState({ width: 0, height: 0 });

  useLayoutEffect(() => {
    const element = stage.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setBox({ width, height });
      const side = Math.max(width, height) * (globalThis.devicePixelRatio || 1);
      onSize?.(Math.min(2400, Math.max(800, Math.round(side / 200) * 200)));
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [onSize]);

  useEffect(() => {
    if (!frame) return;
    let current = true;
    createImageBitmap(frame.blob).then((bitmap) => {
      const target = canvas.current;
      if (current && target) {
        target.width = bitmap.width;
        target.height = bitmap.height;
        colorContext(target, frame.colorSpace).drawImage(bitmap, 0, 0);
        // Slider to glass: from the change that asked for this print to its drawing.
        performance.measure?.("negative-scan-preview", { start: frame.requested });
      }
      bitmap.close();
    });
    return () => {
      current = false;
    };
  }, [frame]);

  // The picture fitted inside the stage.
  const ratio = frame ? frame.width / frame.height : 1;
  const width = Math.min(box.width, box.height * ratio);
  const height = width / ratio;
  const showCrop = mode === "crop" && frame?.view?.cropped === false && !frame.view.negative;
  const showBorder = mode === "border" && frame?.view?.negative && frame.view.cropped === false;

  return (
    <div className="negative-scan-stage" ref={stage} aria-busy={!frame}>
      {frame ? (
        <div className="negative-scan-picture" style={{ width, height }}>
          <canvas
            ref={canvas}
            role="img"
            aria-label={frame.view?.negative ? "Negative" : "Converted positive preview"}
          />
          {showCrop && (
            <CropOverlay recipe={recipe} aspect={aspect} size={{ width, height }} onCrop={onCrop} />
          )}
          {showBorder && (
            <BorderOverlay recipe={recipe} size={{ width, height }} onBorder={onBorder} />
          )}
        </div>
      ) : (
        <span>{placeholder}</span>
      )}
    </div>
  );
}

const unit = (event, element) => {
  const rect = element.getBoundingClientRect();
  return [
    Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)),
    Math.min(1, Math.max(0, (event.clientY - rect.top) / rect.height)),
  ];
};

const areaStyle = (area) => ({
  left: `${area.x * 100}%`,
  top: `${area.y * 100}%`,
  width: `${area.width * 100}%`,
  height: `${area.height * 100}%`,
});

// Drags the crop: a corner resizes it, inside moves it, outside draws a new one. `aspect` is a
// locked width over height, in the picture's own proportions.
function CropOverlay({ recipe, aspect, size, onCrop }) {
  const [draft, setDraft] = useState(null);
  const drag = useRef(null);
  const crop = draft ?? recipe.crop;
  const pictureAspect = size.width / Math.max(1, size.height);
  return (
    <div
      className="negative-scan-overlay"
      onPointerDown={(event) => {
        const point = unit(event, event.currentTarget);
        const tolerance = 14 / Math.max(1, Math.min(size.width, size.height));
        drag.current = { start: point, crop: recipe.crop, hit: hitCrop(recipe.crop, point, tolerance) };
        event.currentTarget.setPointerCapture(event.pointerId);
      }}
      onPointerMove={(event) => {
        if (!drag.current) return;
        setDraft(cropDrag(drag.current, unit(event, event.currentTarget), aspect, pictureAspect));
      }}
      onPointerUp={() => {
        const next = draft;
        drag.current = null;
        setDraft(null);
        if (next && next.width > 0.01 && next.height > 0.01) onCrop(clampArea(next, 0.05));
      }}
    >
      <div className="negative-scan-crop" style={areaStyle(crop)}>
        {["nw", "ne", "sw", "se"].map((corner) => (
          <span key={corner} className={`negative-scan-handle ${corner}`} />
        ))}
      </div>
    </div>
  );
}

// Drags a rectangle over clear film; a click samples a small square around the point, as a tap
// does in the apps.
function BorderOverlay({ recipe, size, onBorder }) {
  const [draft, setDraft] = useState(null);
  const start = useRef(null);
  // Where the border was sampled, shown on the oriented negative (straightening aside).
  const sampled = recipe.borderArea ? orientArea(recipe, recipe.borderArea) : null;
  return (
    <div
      className="negative-scan-overlay picking"
      onPointerDown={(event) => {
        start.current = unit(event, event.currentTarget);
        event.currentTarget.setPointerCapture(event.pointerId);
      }}
      onPointerMove={(event) => {
        if (!start.current) return;
        const [x, y] = unit(event, event.currentTarget);
        const [x0, y0] = start.current;
        setDraft({ x: Math.min(x, x0), y: Math.min(y, y0), width: Math.abs(x - x0), height: Math.abs(y - y0) });
      }}
      onPointerUp={() => {
        const from = start.current;
        start.current = null;
        setDraft(null);
        if (!from) return;
        let area = draft;
        if (!area || area.width * size.width < 4 || area.height * size.height < 4) {
          // A click: 3% of the short side, square on screen.
          const side = 0.03 * Math.min(size.width, size.height);
          const w = side / size.width, h = side / size.height;
          area = { x: from[0] - w / 2, y: from[1] - h / 2, width: w, height: h };
        }
        onBorder(clampArea(area, 0.001));
      }}
    >
      {sampled && !draft && <div className="negative-scan-sample kept" style={areaStyle(sampled)} />}
      {draft && <div className="negative-scan-sample" style={areaStyle(draft)} />}
    </div>
  );
}
