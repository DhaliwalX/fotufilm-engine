// Dragging a crop over a picture, in unit coordinates from the top left.

const clamp = (value, min, max) => Math.min(Math.max(value, min), max);

// What a press at `point` takes hold of: a corner within `tolerance`, the crop to move, or
// nothing, which draws a new crop.
export function hitCrop(crop, [x, y], tolerance) {
  const corners = {
    nw: [crop.x, crop.y],
    ne: [crop.x + crop.width, crop.y],
    sw: [crop.x, crop.y + crop.height],
    se: [crop.x + crop.width, crop.y + crop.height],
  };
  for (const [name, [cx, cy]] of Object.entries(corners))
    if (Math.abs(x - cx) <= tolerance && Math.abs(y - cy) <= tolerance) return name;
  const inside =
    x >= crop.x && x <= crop.x + crop.width && y >= crop.y && y <= crop.y + crop.height;
  // The whole picture has nowhere to move: a drag over it draws a crop.
  const whole = crop.width >= 1 && crop.height >= 1;
  return inside && !whole ? "move" : "new";
}

// The crop a drag from `start` to `point` makes. `aspect` locks width over height in the
// picture's own pixels (`pictureAspect` is the picture's width over height); null is free.
export function cropDrag({ start, crop, hit }, point, aspect, pictureAspect) {
  if (hit === "move") {
    return {
      ...crop,
      x: clamp(crop.x + point[0] - start[0], 0, 1 - crop.width),
      y: clamp(crop.y + point[1] - start[1], 0, 1 - crop.height),
    };
  }
  // The corner opposite the one held stays put; a new crop grows from where the press began.
  const anchor =
    hit === "new"
      ? start
      : [
          hit.includes("w") ? crop.x + crop.width : crop.x,
          hit.includes("n") ? crop.y + crop.height : crop.y,
        ];
  const dx = Math.sign(point[0] - anchor[0]) || 1;
  const dy = Math.sign(point[1] - anchor[1]) || 1;
  // Room from the anchor to the picture's edge in each direction.
  const roomX = dx > 0 ? 1 - anchor[0] : anchor[0];
  const roomY = dy > 0 ? 1 - anchor[1] : anchor[1];
  let width = Math.min(Math.abs(point[0] - anchor[0]), roomX);
  let height = Math.min(Math.abs(point[1] - anchor[1]), roomY);
  if (aspect) {
    // Height in unit terms for this width: (width · pictureAspect) / height = aspect.
    const unitRatio = aspect / pictureAspect;
    if (width / Math.max(height, 1e-9) > unitRatio) width = height * unitRatio;
    else height = width / unitRatio;
    if (width > roomX) {
      width = roomX;
      height = width / unitRatio;
    }
    if (height > roomY) {
      height = roomY;
      width = height * unitRatio;
    }
  }
  return {
    x: dx > 0 ? anchor[0] : anchor[0] - width,
    y: dy > 0 ? anchor[1] : anchor[1] - height,
    width,
    height,
  };
}
