import { useEffect, useRef, useState } from "react";
import { moveCrop, resizeCrop } from "./crop-interaction.js";
import "./CropOverlay.css";
const names = ["Top left", "Top right", "Bottom right", "Bottom left"];

export default function CropOverlay({
  crop,
  shape = "rectangle",
  ratio = "free",
  sourceKey,
  onChange,
  onEnd,
}) {
  const surface = useRef(null),
    drag = useRef(null);
  const [draft, setDraft] = useState(null);
  const key = JSON.stringify([sourceKey, crop, shape, ratio]);
  const currentKey = useRef(key);
  currentKey.current = key;
  const points = draft?.key === key ? draft.points : crop;
  useEffect(() => {
    drag.current = null;
    setDraft(null);
  }, [key]);
  const local = (event, bounds) => [
    (event.clientX - bounds.left) / bounds.width,
    (event.clientY - bounds.top) / bounds.height,
  ];
  function begin(event, grip) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    const bounds = surface.current.getBoundingClientRect();
    drag.current = {
      grip,
      key,
      bounds,
      pointer: event.pointerId,
      start: local(event, bounds),
      points: crop,
    };
    event.currentTarget.setPointerCapture(event.pointerId);
    setDraft({ key, points: crop });
  }
  function move(event) {
    const d = drag.current;
    if (!d || d.pointer !== event.pointerId || d.key !== currentKey.current)
      return;
    const point = local(event, d.bounds);
    const next =
      d.grip === "move"
        ? moveCrop(d.points, point[0] - d.start[0], point[1] - d.start[1])
        : resizeCrop(d.points, d.grip, point, shape, ratio !== "free", [
            Math.min(0.25, 44 / d.bounds.width),
            Math.min(0.25, 44 / d.bounds.height),
          ]);
    d.latest = next;
    setDraft({ key, points: next });
  }
  function finish(event) {
    const d = drag.current;
    drag.current = null;
    if (
      d &&
      d.key === currentKey.current &&
      d.pointer === event.pointerId &&
      d.latest
    ) {
      onChange(d.latest);
      onEnd();
    }
    setDraft(null);
  }
  function cancel() {
    drag.current = null;
    setDraft(null);
  }
  function keyboard(event, grip, point) {
    const delta = {
      ArrowLeft: [-0.005, 0],
      ArrowRight: [0.005, 0],
      ArrowUp: [0, -0.005],
      ArrowDown: [0, 0.005],
    }[event.key];
    if (!delta) return;
    event.preventDefault();
    event.stopPropagation();
    const factor = event.shiftKey ? 10 : 1;
    onChange(
      grip === "move"
        ? moveCrop(crop, delta[0] * factor, delta[1] * factor)
        : resizeCrop(
            crop,
            grip,
            [point[0] + delta[0] * factor, point[1] + delta[1] * factor],
            shape,
            ratio !== "free",
          ),
    );
  }
  const edges =
    shape === "rectangle"
      ? [
          ["top", (points[0][0] + points[1][0]) / 2, points[0][1]],
          ["right", points[1][0], (points[1][1] + points[2][1]) / 2],
          ["bottom", (points[3][0] + points[2][0]) / 2, points[2][1]],
          ["left", points[0][0], (points[0][1] + points[3][1]) / 2],
        ]
      : [];
  return (
    <div
      ref={surface}
      className={`crop-controls ${shape} ${draft ? "dragging" : ""}`}
      onPointerMove={move}
      onPointerUp={finish}
      onPointerCancel={cancel}
      onLostPointerCapture={cancel}
    >
      <svg
        className="crop-overlay"
        viewBox="0 0 1000 1000"
        preserveAspectRatio="none"
        aria-label="Crop selection"
      >
        <path
          d={`M0 0H1000V1000H0Z M${points.map((p) => p.map((v) => v * 1000).join(" ")).join(" L")}Z`}
          fillRule="evenodd"
          fill="#0008"
        />
        <polygon
          className="crop-move-zone"
          points={points.map((p) => p.map((v) => v * 1000).join(",")).join(" ")}
          fill="transparent"
          stroke="white"
          strokeWidth="1.5"
          vectorEffect="non-scaling-stroke"
          onPointerDown={(e) => begin(e, "move")}
          role="button"
          tabIndex={0}
          aria-label="Move crop"
          onKeyDown={(e) => keyboard(e, "move")}
          onKeyUp={onEnd}
        />
        {shape === "rectangle" && (
          <g className="crop-thirds" stroke="#fff9" strokeWidth=".75">
            {[1 / 3, 2 / 3].flatMap((t) => {
              const x =
                  1000 * (points[0][0] + t * (points[2][0] - points[0][0])),
                y = 1000 * (points[0][1] + t * (points[2][1] - points[0][1]));
              return [
                <line
                  key={`x${t}`}
                  x1={x}
                  x2={x}
                  y1={points[0][1] * 1000}
                  y2={points[2][1] * 1000}
                  vectorEffect="non-scaling-stroke"
                />,
                <line
                  key={`y${t}`}
                  y1={y}
                  y2={y}
                  x1={points[0][0] * 1000}
                  x2={points[2][0] * 1000}
                  vectorEffect="non-scaling-stroke"
                />,
              ];
            })}
          </g>
        )}
      </svg>
      {points.map(([x, y], i) => (
        <button
          key={i}
          className="crop-handle"
          aria-label={`${names[i]} crop corner`}
          style={{ left: `${x * 100}%`, top: `${y * 100}%` }}
          onPointerDown={(e) => begin(e, i)}
          onKeyDown={(e) => keyboard(e, i, [x, y])}
          onKeyUp={onEnd}
        />
      ))}
      {edges.map(([side, x, y]) => (
        <button
          key={side}
          className={`crop-handle crop-edge ${side}`}
          aria-label={`${side[0].toUpperCase() + side.slice(1)} crop edge`}
          style={{ left: `${x * 100}%`, top: `${y * 100}%` }}
          onPointerDown={(e) => begin(e, side)}
          onKeyDown={(e) => keyboard(e, side, [x, y])}
          onKeyUp={onEnd}
        />
      ))}
    </div>
  );
}
