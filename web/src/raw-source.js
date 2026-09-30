import { lensSample } from "./lens-correction.js";
import { linearSampler } from "./linear-sampler.js";
import { imageSource } from "./engine.js";
import {
  decodeCanvasPixels,
  imageDataColorSpace,
  sourceContext,
  sourcePixels,
} from "./canvas-color.js";
import { LinearImage } from "./linear-image.js";
import { fullCrop } from "./editor-state.js";
import { homography, mapPoint, outputSize } from "./geometry.js";

// RAW storage remains RGB16 with an exposure scale; EXR storage remains float32.
// Geometry returns scene-linear
// Rec.2020 float tiles, including values above display white;
// a canvas is used only for display, never as an intermediate for film or export.
export function rawSource(
  image,
  edit,
  maxEdge = Infinity,
  cropMode = false,
  lensTable = null,
  perspective = null,
  displaySize = null,
) {
  const originalWidth = image.naturalWidth || image.width,
    originalHeight = image.naturalHeight || image.height;
  const swapped = edit.rotation % 2 !== 0;
  const orientedWidth = swapped ? originalHeight : originalWidth;
  const orientedHeight = swapped ? originalWidth : originalHeight;
  const scale = Math.min(1, maxEdge / Math.max(orientedWidth, orientedHeight));
  const frameWidth = Math.max(1, Math.round(orientedWidth * scale));
  const frameHeight = Math.max(1, Math.round(orientedHeight * scale));
  const crop = cropMode ? fullCrop() : edit.crop;
  const { width, height } =
    displaySize || outputSize(crop, frameWidth, frameHeight);
  const matrix = homography(crop);
  const angle =
    Math.abs(edit.straighten) > 0.001 ? (edit.straighten * Math.PI) / 180 : 0;
  const cos = Math.cos(angle),
    sin = Math.sin(angle);
  const cover = Math.max(
    (orientedWidth * cos + orientedHeight * Math.abs(sin)) / orientedWidth,
    (orientedHeight * cos + orientedWidth * Math.abs(sin)) / orientedHeight,
  );
  const {
    data,
    colors,
    sceneScale = 1,
    profile,
  } = image.linear || image.raw || {};
  const identity =
    !lensTable &&
    !edit.rotation &&
    !edit.flip &&
    !angle &&
    !perspective &&
    width === originalWidth &&
    height === originalHeight &&
    crop.every((point, i) => point.every((v, c) => v === fullCrop()[i][c]));
  const exactCopy = identity && image.linear;
  // Samples fall on pixel centres, so a browser-decoded photo is read region by
  // region rather than pixel by pixel through the sampler.
  const direct = identity && !image.raw && !image.linear ? imageSource(image) : null;
  let strip = null;
  const sample =
    !direct && (lensTable || (!image.raw && !image.linear))
      ? linearSampler(image)
      : null;
  const sampleScale = image.linear ? 1 : sceneScale / 65535;
  function point(u, v) {
    // Native order: lens correction → orientation → straighten → perspective → crop.
    // Pull pixels through the inverse operations to resample the scene only once.
    [u, v] = mapPoint(matrix, u, v);
    if (perspective) [u, v] = mapPoint(perspective, u, v);
    const px = ((u - 0.5) * orientedWidth) / cover;
    const py = ((v - 0.5) * orientedHeight) / cover;
    u = (cos * px + sin * py) / orientedWidth + 0.5;
    v = (-sin * px + cos * py) / orientedHeight + 0.5;
    if (edit.flip) u = 1 - u;
    switch (edit.rotation) {
      case 1:
        return [1 - v, u];
      case 2:
        return [1 - u, 1 - v];
      case 3:
        return [v, 1 - u];
      default:
        return [u, v];
    }
  }
  return {
    width,
    height,
    read(left, top, w, h) {
      if (direct) {
        // Canvas reads cost less per pixel in full-width strips than in tiles,
        // and callers read tiles along a row.
        if (!strip || strip.top !== top || strip.height !== h)
          strip = { top, height: h, data: direct.read(0, top, width, h) };
        const output = new Float32Array(w * h * 4);
        for (let y = 0; y < h; y++) {
          const from = (y * width + left) * 4;
          output.set(strip.data.subarray(from, from + w * 4), y * w * 4);
        }
        for (let i = 3; i < output.length; i += 4) output[i] = 1;
        return output;
      }
      const output = new Float32Array(w * h * 4);
      if (exactCopy) {
        for (let y = 0; y < h; y++) {
          const from = ((top + y) * width + left) * 4;
          output.set(data.subarray(from, from + w * 4), y * w * 4);
        }
        return output;
      }
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++) {
          const [u, v] = point(
            (left + x + 0.5) / width,
            (top + y + 0.5) / height,
          );
          if (sample) {
            const i = (y * w + x) * 4;
            for (let c = 0; c < 3; c++) {
              const [sx, sy, gain] = lensTable
                ? lensSample(lensTable, u, v, originalWidth, originalHeight, c)
                : [u * originalWidth - 0.5, v * originalHeight - 0.5, 1];
              output[i + c] = sample(sx, sy, c) * gain;
            }
            output[i + 3] = 1;
            continue;
          }
          const sx = Math.max(
            0,
            Math.min(originalWidth - 1, u * originalWidth - 0.5),
          );
          const sy = Math.max(
            0,
            Math.min(originalHeight - 1, v * originalHeight - 0.5),
          );
          const ix = Math.floor(sx),
            iy = Math.floor(sy),
            fx = sx - ix,
            fy = sy - iy;
          const nx = Math.min(ix + 1, originalWidth - 1),
            ny = Math.min(iy + 1, originalHeight - 1);
          const i = (y * w + x) * 4;
          for (let c = 0; c < 3; c++) {
            const channel = colors === 1 ? 0 : c;
            const a = data[(iy * originalWidth + ix) * colors + channel];
            const b = data[(iy * originalWidth + nx) * colors + channel];
            const d = data[(ny * originalWidth + ix) * colors + channel];
            const e = data[(ny * originalWidth + nx) * colors + channel];
            output[i + c] =
              ((a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy) *
              sampleScale;
          }
          // This linear transform commutes with interpolation. Apply it once,
          // after RGB16 expansion, preserving negative colors and values above 1.
          if (profile) {
            const m = profile.matrix,
              r = output[i],
              g = output[i + 1],
              b = output[i + 2];
            output[i] = m[0] * r + m[1] * g + m[2] * b;
            output[i + 1] = m[3] * r + m[4] * g + m[5] * b;
            output[i + 2] = m[6] * r + m[7] * g + m[8] * b;
          }
          output[i + 3] = 1;
        }
      return output;
    },
  };
}

// A scene-linear copy of a browser-decoded photo, scaled by the browser so its
// longer edge is at most `edge` pixels.
export function scaledLinearImage(image, edge) {
  const w = image.naturalWidth || image.width,
    h = image.naturalHeight || image.height;
  const scale = Math.min(1, edge / Math.max(w, h));
  const width = Math.max(1, Math.round(w * scale)),
    height = Math.max(1, Math.round(h * scale));
  const canvas =
    typeof OffscreenCanvas !== "undefined"
      ? new OffscreenCanvas(width, height)
      : Object.assign(document.createElement("canvas"), { width, height });
  const context = sourceContext(canvas);
  context.drawImage(image, 0, 0, width, height);
  const pixels = sourcePixels(context, 0, 0, width, height);
  return new LinearImage({
    pixels: decodeCanvasPixels(pixels.data, imageDataColorSpace(pixels)),
    width,
    height,
  });
}
