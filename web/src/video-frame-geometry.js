// Geometry follows linear-light decoding on both GPU and CPU.
export function orientVideoPixels(decoded, sample, width, height) {
  const rotation = sample.rotation;
  const displayWidth = sample.displayWidth,
    displayHeight = sample.displayHeight;
  if (rotation === 0 && displayWidth === width && displayHeight === height)
    return {
      naturalWidth: width,
      naturalHeight: height,
      linear: { data: decoded, colors: 4 },
    };
  // Apply container orientation and pixel aspect ratio in float, after the input
  // curve. Geometry in the editor then operates in the displayed coordinate system.
  const pixels = new Float32Array(displayWidth * displayHeight * 4);
  for (let y = 0; y < displayHeight; y++)
    for (let x = 0; x < displayWidth; x++) {
      let u = (x + 0.5) / displayWidth,
        v = (y + 0.5) / displayHeight;
      if (rotation === 90) [u, v] = [v, 1 - u];
      else if (rotation === 180) [u, v] = [1 - u, 1 - v];
      else if (rotation === 270) [u, v] = [1 - v, u];
      const sx = Math.max(0, Math.min(width - 1, u * width - 0.5)),
        sy = Math.max(0, Math.min(height - 1, v * height - 0.5));
      const ix = Math.floor(sx),
        iy = Math.floor(sy),
        nx = Math.min(ix + 1, width - 1),
        ny = Math.min(iy + 1, height - 1);
      const fx = sx - ix,
        fy = sy - iy,
        target = (y * displayWidth + x) * 4;
      for (let c = 0; c < 4; c++)
        pixels[target + c] =
          ((1 - fx) * decoded[(iy * width + ix) * 4 + c] +
            fx * decoded[(iy * width + nx) * 4 + c]) *
            (1 - fy) +
          ((1 - fx) * decoded[(ny * width + ix) * 4 + c] +
            fx * decoded[(ny * width + nx) * 4 + c]) *
            fy;
    }
  return {
    naturalWidth: displayWidth,
    naturalHeight: displayHeight,
    linear: { data: pixels, colors: 4 },
  };
}
