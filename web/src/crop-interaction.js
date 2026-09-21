import { validCrop } from "./editor-state.js";
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
export const rectangleCrop = (left, top, right, bottom) => [
  [left, top],
  [right, top],
  [right, bottom],
  [left, bottom],
];
export const isRectangleCrop = (p) =>
  p?.length === 4 &&
  p[0][0] === p[3][0] &&
  p[1][0] === p[2][0] &&
  p[0][1] === p[1][1] &&
  p[2][1] === p[3][1];

export function moveCrop(points, dx, dy) {
  dx = clamp(
    dx,
    -Math.min(...points.map((p) => p[0])),
    1 - Math.max(...points.map((p) => p[0])),
  );
  dy = clamp(
    dy,
    -Math.min(...points.map((p) => p[1])),
    1 - Math.max(...points.map((p) => p[1])),
  );
  return points.map(([x, y]) => [x + dx, y + dy]);
}
export function resizeCrop(
  points,
  grip,
  point,
  shape,
  locked,
  minimum = [0.01, 0.01],
) {
  const [x, y] = point.map((v) => clamp(v, 0, 1));
  if (shape === "corners") {
    const next = points.map((p) => [...p]);
    next[grip] = [x, y];
    return validCrop(next) ? next : points;
  }
  let [left, top] = points[0],
    [right, bottom] = points[2];
  const ratio = (right - left) / (bottom - top);
  if (typeof grip === "number") {
    const [ax, ay] = points[(grip + 2) % 4],
      sx = grip === 0 || grip === 3 ? -1 : 1,
      sy = grip < 2 ? -1 : 1;
    let w = clamp((x - ax) * sx, minimum[0], sx < 0 ? ax : 1 - ax);
    let h = clamp((y - ay) * sy, minimum[1], sy < 0 ? ay : 1 - ay);
    if (locked) {
      w = Math.min(
        Math.max(w, h * ratio),
        sx < 0 ? ax : 1 - ax,
        (sy < 0 ? ay : 1 - ay) * ratio,
      );
      h = w / ratio;
    }
    left = sx < 0 ? ax - w : ax;
    right = sx < 0 ? ax : ax + w;
    top = sy < 0 ? ay - h : ay;
    bottom = sy < 0 ? ay : ay + h;
  } else if (grip === "left" || grip === "right") {
    if (grip === "left") left = clamp(x, 0, right - minimum[0]);
    else right = clamp(x, left + minimum[0], 1);
    if (locked) {
      const cy = (top + bottom) / 2,
        w = Math.min(right - left, 2 * Math.min(cy, 1 - cy) * ratio);
      if (grip === "left") left = right - w;
      else right = left + w;
      top = cy - w / ratio / 2;
      bottom = cy + w / ratio / 2;
    }
  } else {
    if (grip === "top") top = clamp(y, 0, bottom - minimum[1]);
    else bottom = clamp(y, top + minimum[1], 1);
    if (locked) {
      const cx = (left + right) / 2,
        h = Math.min(bottom - top, (2 * Math.min(cx, 1 - cx)) / ratio);
      if (grip === "top") top = bottom - h;
      else bottom = top + h;
      left = cx - (h * ratio) / 2;
      right = cx + (h * ratio) / 2;
    }
  }
  const next = rectangleCrop(left, top, right, bottom);
  return validCrop(next) ? next : points;
}
