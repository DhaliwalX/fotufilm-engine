import { clamp } from "./color-controls.js";

export function constrainPhotoOffset(offset, zoom, display, room) {
  return offset.map((value, axis) => {
    const limit = Math.max(0, (display[axis] * zoom - room[axis]) / 2);
    return limit === 0 ? 0 : clamp(value, -limit, limit);
  });
}

// Anchors are measured from the viewer centre. This also handles a moving pinch
// midpoint, so the point between the fingers remains under those fingers.
export function anchoredPhotoZoom({
  zoom,
  offset,
  anchor,
  nextAnchor = anchor,
  scale,
  display,
  room,
}) {
  const nextZoom = clamp(zoom * scale, 1, 8);
  const ratio = nextZoom / zoom;
  const nextOffset = anchor.map(
    (value, axis) => nextAnchor[axis] - (value - offset[axis]) * ratio,
  );
  return {
    zoom: nextZoom,
    offset: constrainPhotoOffset(nextOffset, nextZoom, display, room),
  };
}

export function pinchGeometry(points) {
  const [a, b] = points;
  return {
    anchor: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2],
    distance: Math.max(1, Math.hypot(a[0] - b[0], a[1] - b[1])),
  };
}
