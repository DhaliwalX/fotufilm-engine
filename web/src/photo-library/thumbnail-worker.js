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

// The smallest embedded preview that still covers the decode size, else the
// largest. `minimum` and `aspect` reject previews too small or letterboxed to
// stand in for the photo itself.
async function choosePreview(
  file,
  previews,
  edge,
  { minimum = 0, aspect } = {},
) {
  const sized = [];
  for (const preview of validPreviews(previews, file.size)) {
    const head = new Uint8Array(
      await file.slice(preview.offset, preview.offset + 65536).arrayBuffer(),
    );
    const size = jpegSize(head);
    if (!size?.width || !size?.height) continue;
    const quarter = size.orientation >= 5,
      ratio = quarter ? size.height / size.width : size.width / size.height;
    if (Math.max(size.width, size.height) < minimum) continue;
    if (aspect && Math.abs(ratio / aspect - 1) > 0.02) continue;
    sized.push({ ...preview, ...size });
  }
  const long = (item) => Math.max(item.width, item.height);
  sized.sort((a, b) => long(a) - long(b));
  return sized.find((item) => long(item) >= edge * 2) || sized.at(-1);
}

// The container's orientation applies unless the preview carries its own.
async function decodePreview(file, previews, edge, orientation, options) {
  const preview = await choosePreview(file, previews, edge, options);
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
  // Phones embed an EXIF thumbnail; a large enough one decodes ~20× faster.
  if (probe.format === "jpeg")
    return (
      (probe.width &&
        probe.height &&
        (await decodePreview(file, probe.previews, edge, orientation, {
          minimum: edge,
          aspect: probe.width / probe.height,
        }))) ||
      decode(file, { ...probe, exif: orientation }, edge)
    );
  // TIFF outside Safari has no browser decoder; many carry a JPEG preview like a raw.
  if (probe.format === "tiff")
    return (
      (await decode(file, { ...probe, exif: orientation }, edge).catch(
        () => null,
      )) || decodePreview(file, probe.previews, edge, orientation)
    );
  return decode(file, probe, edge);
}

const ROTATION_ORIENTATION = { 0: 1, 90: 6, 180: 3, 270: 8 };
let media;
// The first frame through WebCodecs. Null when this browser cannot decode the
// codec, and the page falls back to a <video> element.
async function videoFrame(file, edge) {
  media ??= import("mediabunny");
  const { Input, BlobSource, ALL_FORMATS, VideoSampleSink } = await media;
  const input = new Input({
    source: new BlobSource(file, { maxCacheSize: 4 << 20 }),
    formats: ALL_FORMATS,
  });
  try {
    const track = await input.getPrimaryVideoTrack();
    if (!track || !(await track.canDecode())) return null;
    const sample = await new VideoSampleSink(track).getSample(
      Math.max(0, await track.getFirstTimestamp()),
    );
    if (!sample) return null;
    try {
      const width = sample.squarePixelWidth,
        height = sample.squarePixelHeight,
        scale = Math.min(1, (edge * 2) / Math.max(width, height));
      const canvas = new OffscreenCanvas(
        Math.max(1, Math.round(width * scale)),
        Math.max(1, Math.round(height * scale)),
      );
      sample.draw(canvas.getContext("2d"), 0, 0, canvas.width, canvas.height);
      return {
        bitmap: canvas.transferToImageBitmap(),
        orientation: ROTATION_ORIENTATION[sample.rotation] ?? 1,
      };
    } finally {
      sample.close();
    }
  } finally {
    input.dispose();
  }
}

async function thumbnail({ file, bitmap, kind, edge, runtime }) {
  const resample = await loadResampler(runtime);
  const decoded = bitmap
    ? { bitmap, orientation: 1 }
    : kind === "video"
      ? await videoFrame(file, edge).catch(() => null)
      : await source(file, kind, edge);
  if (!decoded && kind === "video" && !bitmap) return { fallback: true };
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
