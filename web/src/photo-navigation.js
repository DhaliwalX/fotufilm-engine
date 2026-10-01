import { clamp } from "./color-controls.js";

export const MAX_ZOOM = 8;

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
  const nextZoom = clamp(zoom * scale, 1, MAX_ZOOM);
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

// A wheel event's distance in pixels, whatever unit it came in.
export function wheelDistance(
  { deltaX = 0, deltaY = 0, deltaMode = 0 },
  pageHeight = 800,
) {
  const unit = deltaMode === 1 ? 16 : deltaMode === 2 ? pageHeight : 1;
  return [deltaX * unit, deltaY * unit];
}

// How far one zooming wheel event zooms: in proportion to how far it scrolls, as the Mac app's
// canvas does, so a trackpad's stream of small steps zooms as smoothly as a mouse wheel's
// notches. A pinch reaches the page as a wheel event with ctrlKey and deltaY = -100·ln(scale)
// (where the host does not send it exactly: usePhotoNavigation.js), which this inverts. A
// scroll's step is capped at a quarter: a notch of a mouse wheel scrolls about 40 px on a Mac but
// 100 px or more on Windows and Linux.
export function wheelZoomScale(event, pageHeight = 800) {
  const pixels = wheelDistance(event, pageHeight)[1];
  return event.ctrlKey
    ? clamp(Math.exp(-pixels / 100), 0.5, 2)
    : clamp(Math.exp(-pixels / 300), 0.8, 1.25);
}

// A scroll moves a magnified photograph the way the fingers or the wheel move, as a scroll view
// does; a fitted one stays put.
export function scrolledPhotoView({ zoom, offset, display, room }, distance) {
  return {
    zoom,
    offset: constrainPhotoOffset(
      offset.map((value, axis) => value - distance[axis]),
      zoom,
      display,
      room,
    ),
  };
}

export function pinchGeometry(points) {
  const [a, b] = points;
  return {
    anchor: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2],
    distance: Math.max(1, Math.hypot(a[0] - b[0], a[1] - b[1])),
  };
}
