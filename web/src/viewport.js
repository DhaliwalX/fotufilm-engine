// CSS-space intersection -> image-space pixels. The virtual full image grows
// with zoom, but the delivered buffer is bounded by the device-pixel viewport.
export function visiblePhotoViewport({
  room,
  displayWidth,
  displayHeight,
  zoom,
  offset,
  framePlan,
  pixelRatio = 1,
}) {
  const placement = framePlan?.placement;
  const photo = placement
    ? {
        x: placement.image.x / placement.size.width,
        y:
          (placement.size.height - placement.image.y - placement.image.height) /
          placement.size.height,
        width: placement.image.width / placement.size.width,
        height: placement.image.height / placement.size.height,
      }
    : { x: 0, y: 0, width: 1, height: 1 };
  const planeWidth = displayWidth * zoom,
    planeHeight = displayHeight * zoom;
  const left = (room[0] - planeWidth) / 2 + offset[0] + photo.x * planeWidth;
  const top = (room[1] - planeHeight) / 2 + offset[1] + photo.y * planeHeight;
  const cssWidth = planeWidth * photo.width,
    cssHeight = planeHeight * photo.height;
  const width = Math.max(1, Math.round(cssWidth * pixelRatio));
  const height = Math.max(1, Math.round(cssHeight * pixelRatio));
  const x = Math.max(0, Math.floor((-left / cssWidth) * width));
  const y = Math.max(0, Math.floor((-top / cssHeight) * height));
  const right = Math.min(width, Math.ceil(((room[0] - left) / cssWidth) * width));
  const bottom = Math.min(
    height,
    Math.ceil(((room[1] - top) / cssHeight) * height),
  );
  if (right <= x || bottom <= y || room[0] <= 1 || room[1] <= 1) return null;
  return {
    width,
    height,
    region: { x, y, width: right - x, height: bottom - y },
    photo,
  };
}

export function viewportPlacement(viewport) {
  const { width, height, region, photo } = viewport;
  return {
    left: `${100 * (photo.x + (region.x / width) * photo.width)}%`,
    top: `${100 * (photo.y + (region.y / height) * photo.height)}%`,
    width: `${((100 * region.width) / width) * photo.width}%`,
    height: `${((100 * region.height) / height) * photo.height}%`,
  };
}
