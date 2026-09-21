import { INGEST_COLOR } from "./engine-constants.js";

export function halfFloat(value) {
  const sign = value & 0x8000 ? -1 : 1,
    exponent = (value >> 10) & 31,
    fraction = value & 1023;
  return (
    sign *
    (exponent === 0
      ? fraction * 2 ** -24
      : exponent === 31
        ? fraction
          ? NaN
          : Infinity
        : (1 + fraction / 1024) * 2 ** (exponent - 15))
  );
}

// EXIF maps the stored raster into the displayed orientation. Materialize it
// once so crop, lens correction, metadata and the browser's SDR reference agree.
export function orientedPixel(x, y, width, height, orientation) {
  switch (orientation) {
    case 2:
      return [width - 1 - x, y];
    case 3:
      return [width - 1 - x, height - 1 - y];
    case 4:
      return [x, height - 1 - y];
    case 5:
      return [y, x];
    case 6:
      return [height - 1 - y, x];
    case 7:
      return [height - 1 - y, width - 1 - x];
    case 8:
      return [y, width - 1 - x];
    default:
      return [x, y];
  }
}

export function decodeHDRPixels(
  half,
  width,
  height,
  stride,
  gamut,
  orientation = 1,
) {
  const matrix =
    gamut === 0
      ? INGEST_COLOR.linearSRGBToRec2020
      : gamut === 1
        ? INGEST_COLOR.linearDisplayP3ToRec2020
        : null;
  if (![0, 1, 2].includes(gamut))
    throw new Error("Unsupported HDR color primaries.");
  const swapped = orientation >= 5 && orientation <= 8,
    outWidth = swapped ? height : width,
    outHeight = swapped ? width : height;
  const pixels = new Float32Array(outWidth * outHeight * 4);
  const lookup = Float32Array.from({ length: 65536 }, (_, value) =>
    halfFloat(value),
  );
  const dx =
    ([2, 3, 7, 8].includes(orientation) ? -1 : 1) *
    (swapped ? outWidth : 1) *
    4;
  for (let y = 0; y < height; y++) {
    const [ox, oy] = orientedPixel(0, y, width, height, orientation);
    let at = (oy * outWidth + ox) * 4;
    for (let x = 0; x < width; x++, at += dx) {
      const i = (y * stride + x) * 4,
        r = lookup[half[i]],
        g = lookup[half[i + 1]],
        b = lookup[half[i + 2]];
      if (!Number.isFinite(r) || !Number.isFinite(g) || !Number.isFinite(b))
        throw new Error("The HDR image contains invalid pixel values.");
      if (matrix)
        for (let c = 0; c < 3; c++)
          pixels[at + c] =
            matrix[c * 3] * r + matrix[c * 3 + 1] * g + matrix[c * 3 + 2] * b;
      else {
        pixels[at] = r;
        pixels[at + 1] = g;
        pixels[at + 2] = b;
      }
      pixels[at + 3] = 1;
    }
  }
  return { pixels, width: outWidth, height: outHeight };
}

// Same robust middle-tone placement as Core SceneExposureCalibration. This
// changes one global exposure only; highlights and color ratios remain intact.
export function referenceGain(hdr, sdr) {
  if (hdr.length !== sdr.length || hdr.length < 4 || hdr.length % 4) return 1;
  const count = hdr.length / 4,
    stride = Math.max(1, Math.floor(count / 65536)),
    offsets = [];
  const weights = INGEST_COLOR.luminanceWeights;
  const luminance = (values, i) =>
    weights.reduce((sum, w, c) => sum + w * values[i + c], 0);
  for (let p = 0; p < count; p += stride) {
    const reference = luminance(sdr, p * 4),
      scene = luminance(hdr, p * 4);
    if (
      reference >= 0.01 &&
      reference <= 0.65 &&
      Number.isFinite(scene) &&
      scene > 0
    )
      offsets.push(Math.log2(scene / reference));
  }
  if (offsets.length < Math.min(64, Math.max(8, Math.floor(count / 16))))
    return 1;
  offsets.sort((a, b) => a - b);
  const middle = Math.floor(offsets.length / 2),
    median =
      offsets.length % 2
        ? offsets[middle]
        : (offsets[middle - 1] + offsets[middle]) * 0.5;
  return Number.isFinite(median) && median > 0
    ? Math.min(1, Math.max(0.25, 2 ** -median))
    : 1;
}

export function calibrateHDR(result, reference) {
  if (!reference) return 1;
  const { pixels, width, height } = result,
    sample = new Float32Array(reference.pixels.length);
  // Paired, identically oriented whole-image samples; never meter a crop.
  for (let y = 0; y < reference.height; y++)
    for (let x = 0; x < reference.width; x++) {
      const sx = Math.max(
          0,
          Math.min(width - 1, ((x + 0.5) * width) / reference.width - 0.5),
        ),
        sy = Math.max(
          0,
          Math.min(height - 1, ((y + 0.5) * height) / reference.height - 0.5),
        ),
        ix = Math.floor(sx),
        iy = Math.floor(sy),
        fx = sx - ix,
        fy = sy - iy,
        nx = Math.min(width - 1, ix + 1),
        ny = Math.min(height - 1, iy + 1);
      for (let c = 0; c < 3; c++) {
        const a = pixels[(iy * width + ix) * 4 + c],
          b = pixels[(iy * width + nx) * 4 + c],
          d = pixels[(ny * width + ix) * 4 + c],
          e = pixels[(ny * width + nx) * 4 + c];
        sample[(y * reference.width + x) * 4 + c] =
          (a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy;
      }
    }
  const gain = referenceGain(sample, reference.pixels);
  if (gain !== 1)
    for (let i = 0; i < pixels.length; i += 4)
      for (let c = 0; c < 3; c++) pixels[i + c] *= gain;
  return gain;
}
