import { useLayoutEffect, useRef } from "react";
import { useBackend } from "./backend/BackendContext.jsx";
import { viewportFraction } from "./viewport.js";

// Nothing on show: the host draws no image and the page paints its canvas whole.
const EMPTY = Object.freeze({ clip: [0, 0, 0, 0], source: "developed", layers: [] });

const rect = ({ x, y, width, height }) => [x, y, width, height];

function intersect(a, b) {
  const x = Math.max(a.x, b.x),
    y = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.width, b.x + b.width),
    bottom = Math.min(a.y + a.height, b.y + b.height);
  return right > x && bottom > y
    ? { x, y, width: right - x, height: bottom - y }
    : { x: 0, y: 0, width: 0, height: 0 };
}

// Where the page's canvas lets the image layer show through: the backgrounds painted under the
// photograph (the page's and the viewer's, styles/viewer.css) leave this rectangle out.
function setHole(element, hole, origin = { x: 0, y: 0 }) {
  if (!element) return;
  element.style.setProperty("--image-hole-x", `${hole.x - origin.x}px`);
  element.style.setProperty("--image-hole-y", `${hole.y - origin.y}px`);
  element.style.setProperty("--image-hole-width", `${hole.width}px`);
  element.style.setProperty("--image-hole-height", `${hole.height}px`);
}

/**
 * Native presentation (web/src/backend/README.md): when the backend's host draws the photograph
 * itself, beneath the page, the canvas keeps the page transparent over the photograph and tells
 * the host where the presented frames go, every time the layout or the frames change. Returns
 * whether the photograph on show is the host's, in which case the page draws no picture of it.
 */
export function useImageLayer({ container, plane, result, detail, compare }) {
  const backend = useBackend();
  const enabled = backend.imageLayer === true;
  const active = enabled && !!result?.presented;
  const sent = useRef("");
  const viewer = useRef(null);

  useLayoutEffect(() => {
    if (!enabled) return;
    document.documentElement.classList.add("native-image-layer");
    return () => {
      document.documentElement.classList.remove("native-image-layer");
      const none = { x: 0, y: 0, width: 0, height: 0 };
      setHole(document.documentElement, none);
      setHole(viewer.current, none);
      sent.current = "";
      backend.placeImageLayer(EMPTY);
    };
  }, [enabled, backend]);

  // After every render: the photograph moves with zoom, pan, the window and the panels.
  useLayoutEffect(() => {
    if (!enabled) return;
    let geometry = EMPTY,
      hole = { x: 0, y: 0, width: 0, height: 0 };
    const box = container.current?.getBoundingClientRect();
    const photo = plane.current?.getBoundingClientRect();
    if (active && box && photo) {
      const layers = [
        {
          slot: "preview",
          frame: result.presented.frame,
          original: result.presented.original,
          rect: rect(photo),
        },
      ];
      if (detail?.presented) {
        const part = viewportFraction(detail.viewport);
        layers.push({
          slot: "detail",
          frame: detail.presented.frame,
          original: detail.presented.original,
          rect: [
            photo.x + part.left * photo.width,
            photo.y + part.top * photo.height,
            part.width * photo.width,
            part.height * photo.height,
          ],
        });
      }
      geometry = { clip: rect(box), source: compare ? "original" : "developed", layers };
      hole = intersect(photo, box);
    }
    setHole(document.documentElement, hole);
    viewer.current = container.current?.closest(".viewer") ?? null;
    setHole(viewer.current, hole, viewer.current?.getBoundingClientRect());
    const key = JSON.stringify(geometry);
    if (key === sent.current) return;
    sent.current = key;
    backend.placeImageLayer(geometry);
  });

  return active;
}
