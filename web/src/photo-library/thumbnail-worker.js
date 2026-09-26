import {
  jpegSize,
  probeImage,
  PROBE_BYTES,
  validPreviews,
} from "./image-probe.js";
import { createResampler } from "./thumbnail-resampler.js";
import { relatedAssetUrl } from "../runtime-assets.js";

let resampler;
function loadResampler(url) {
  resampler ??= import(/* @vite-ignore */ url)
    .then(({ default: create }) =>
      create({ locateFile: (name) => relatedAssetUrl(name, url) }),
    )
    .then(createResampler)
    .catch((error) => {
      resampler = null;
      throw error;
    });
  return resampler;
}

// The browser decodes (a JPEG decoder can skip most of a large photo when asked
// for a smaller one) and applies any orientation the JPEG itself records; Chrome
// ignores imageOrientation "none", so that is never asked for. Halide resamples
// from about twice the thumbnail size and applies `orientation`, which only a raw
// container supplies. `width` and `height` are the stored size, before EXIF.
async function decode(
  blob,
  { width = 0, height = 0, exif = 1 },
  edge,
  orientation = 1,
) {
  if (exif >= 5) [width, height] = [height, width];
  const long = Math.max(width, height),
    target = edge * 2,
    options = {};
  if (long > target) {
    if (width >= height)
      options.resizeWidth = Math.round((width * target) / long);
    else options.resizeHeight = Math.round((height * target) / long);
    options.resizeQuality = "medium";
  }
  return { bitmap: await createImageBitmap(blob, options), orientation };
}

// The smallest embedded preview that still covers the decode size, else the largest.
async function choosePreview(file, previews, edge) {
  const sized = [];
  for (const preview of validPreviews(previews, file.size)) {
    const head = new Uint8Array(
      await file.slice(preview.offset, preview.offset + 65536).arrayBuffer(),
    );
    const size = jpegSize(head);
    if (size?.width && size?.height) sized.push({ ...preview, ...size });
  }
  const long = (item) => Math.max(item.width, item.height);
  sized.sort((a, b) => long(a) - long(b));
  return sized.find((item) => long(item) >= edge * 2) || sized.at(-1);
}

// A raw's orientation applies unless its preview already carries one.
async function decodePreview(file, previews, edge, orientation) {
  const preview = await choosePreview(file, previews, edge);
  if (!preview) return null;
  return decode(
    file.slice(preview.offset, preview.offset + preview.length, "image/jpeg"),
    { width: preview.width, height: preview.height, exif: preview.orientation },
    edge,
    preview.orientation === 1 ? orientation : 1,
  );
}

async function source(file, kind, edge) {
  const head = new Uint8Array(await file.slice(0, PROBE_BYTES).arrayBuffer());
  const probe = probeImage(head, file.size);
  const orientation =
    probe.orientation >= 1 && probe.orientation <= 8 ? probe.orientation : 1;
  if (kind === "raw" || probe.format === "raw")
    return decodePreview(file, probe.previews, edge, orientation);
  if (probe.format === "jpeg")
    return decode(file, { ...probe, exif: orientation }, edge);
  // TIFF outside Safari has no browser decoder; many carry a JPEG preview like a raw.
  if (probe.format === "tiff")
    return (
      (await decode(file, { ...probe, exif: orientation }, edge).catch(
        () => null,
      )) || decodePreview(file, probe.previews, edge, orientation)
    );
  return decode(file, probe, edge);
}

async function thumbnail({ file, bitmap, kind, edge, runtime }) {
  const resample = await loadResampler(runtime);
  const decoded = bitmap
    ? { bitmap, orientation: 1 }
    : await source(file, kind, edge);
  if (!decoded) return null;
  const { width, height } = decoded.bitmap;
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context.drawImage(decoded.bitmap, 0, 0);
  decoded.bitmap.close();
  const small = resample(
    context.getImageData(0, 0, width, height).data,
    width,
    height,
    edge,
    decoded.orientation || 1,
  );
  const output = new OffscreenCanvas(small.width, small.height);
  output
    .getContext("2d")
    .putImageData(new ImageData(small.pixels, small.width, small.height), 0, 0);
  return {
    blob: await output.convertToBlob({ type: "image/jpeg", quality: 0.86 }),
    width: small.width,
    height: small.height,
  };
}

self.onmessage = async ({ data }) => {
  try {
    self.postMessage({ id: data.id, result: await thumbnail(data) });
  } catch (error) {
    self.postMessage({ id: data.id, error: error.message || String(error) });
  }
};
