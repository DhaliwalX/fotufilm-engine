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

// The view at another zoom about the viewer's centre, for the toolbar's, keys' and menu's steps.
export function centredPhotoZoom({ zoom, offset, nextZoom, display, room }) {
  const ratio = nextZoom / zoom;
  return {
    zoom: nextZoom,
    offset: constrainPhotoOffset(
      offset.map((value) => value * ratio),
      nextZoom,
      display,
      room,
    ),
  };
}

// How far one wheel event zooms: in proportion to how far it scrolls, as the Mac app's canvas
// does, so a trackpad's stream of small steps zooms as smoothly as a mouse wheel's notches. A
// trackpad pinch arrives as a wheel event with ctrlKey and deltaY = -100·ln(scale), which this
// inverts exactly.
export function wheelZoomScale(
  { deltaY, deltaMode = 0, ctrlKey = false },
  pageHeight = 800,
) {
  const pixels =
    deltaMode === 1
      ? deltaY * 16
      : deltaMode === 2
        ? deltaY * pageHeight
        : deltaY;
  return clamp(Math.exp(-pixels / (ctrlKey ? 100 : 300)), 0.5, 2);
}

export function pinchGeometry(points) {
  const [a, b] = points;
  return {
    anchor: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2],
    distance: Math.max(1, Math.hypot(a[0] - b[0], a[1] - b[1])),
  };
}
