// Reads just enough of a file's head to thumbnail it: pixel size, EXIF orientation and,
// for raws, where the camera's embedded JPEG previews are. TIFF-based raws (DNG, CR2, NEF,
// ARW, PEF, RW2…) list previews in their IFDs, RAF has a fixed header field, and CR3 keeps
// its orientation in a CMT1 box and its previews behind plain JPEG start markers.
export const PROBE_BYTES = 1 << 20;

const TYPE_SIZE = { 1: 1, 2: 1, 3: 2, 4: 4, 7: 1, 13: 4 };
const ascii = (bytes, at, length) =>
  String.fromCharCode(...bytes.subarray(at, at + length));

function readTiff(bytes, base = 0) {
  const view = new DataView(
    bytes.buffer,
    bytes.byteOffset + base,
    bytes.byteLength - base,
  );
  if (view.byteLength < 8) return null;
  const little = view.getUint16(0) === 0x4949;
  if (!little && view.getUint16(0) !== 0x4d4d) return null;
  const u16 = (at) => view.getUint16(at, little),
    u32 = (at) => view.getUint32(at, little);
  const previews = [],
    visited = new Set();
  let orientation = 1,
    width = 0,
    height = 0;
  const values = (entry) => {
    const size = TYPE_SIZE[u16(entry + 2)],
      count = u32(entry + 4);
    if (!size || count > 64) return [];
    const at = size * count <= 4 ? entry + 8 : u32(entry + 8);
    if (at + size * count > view.byteLength) return [];
    return Array.from({ length: count }, (_, i) =>
      size === 4
        ? u32(at + i * 4)
        : size === 2
          ? u16(at + i * 2)
          : view.getUint8(at + i),
    );
  };
  function walk(offset, depth) {
    for (let chain = 0; offset && chain < 4 && !visited.has(offset); chain++) {
      visited.add(offset);
      if (offset + 2 > view.byteLength) return;
      const count = u16(offset);
      if (offset + 6 + count * 12 > view.byteLength) return;
      const tags = new Map();
      for (let i = 0; i < count; i++)
        tags.set(u16(offset + 2 + i * 12), offset + 2 + i * 12);
      const all = (tag) => (tags.has(tag) ? values(tags.get(tag)) : []);
      const first = (tag) => all(tag)[0];
      if (depth === 0 && chain === 0) {
        orientation = first(0x0112) || 1;
        width = first(0x0100) || 0;
        height = first(0x0101) || 0;
      }
      // JPEGInterchangeFormat and its length.
      if (tags.has(0x0201) && tags.has(0x0202))
        previews.push({ offset: first(0x0201), length: first(0x0202) });
      // Panasonic's JpgFromRaw: a whole JPEG as an UNDEFINED value.
      if (tags.has(0x002e)) {
        const entry = tags.get(0x002e);
        previews.push({ offset: u32(entry + 8), length: u32(entry + 4) });
      }
      // A single JPEG strip. Compression 7 also stores lossless raw mosaics, so it
      // counts only with RGB or YCbCr photometry.
      const strips = all(0x0111),
        stripBytes = all(0x0117),
        compression = first(0x0103),
        photometric = first(0x0106);
      if (
        strips.length === 1 &&
        stripBytes.length === 1 &&
        (compression === 6 ||
          (compression === 7 && (photometric === 2 || photometric === 6)))
      )
        previews.push({ offset: strips[0], length: stripBytes[0] });
      for (const child of all(0x014a)) walk(child, depth + 1);
      offset = u32(offset + 2 + count * 12);
    }
  }
  walk(u32(4), 0);
  return {
    orientation,
    width,
    height,
    previews: previews.map(({ offset, length }) => ({
      offset: offset + base,
      length,
    })),
  };
}

// Size, EXIF orientation and the EXIF thumbnail (IFD1), which phones make
// large enough to use: Samsung stores 512 × 384.
function readJpeg(bytes) {
  let orientation = 1,
    previews = [];
  for (let at = 2; at + 9 < bytes.length; ) {
    if (bytes[at] !== 0xff) return null;
    const marker = bytes[at + 1];
    if (marker === 0xff) {
      at++;
      continue;
    }
    const length = (bytes[at + 2] << 8) | bytes[at + 3];
    if (marker === 0xe1 && ascii(bytes, at + 4, 4) === "Exif") {
      const exif = readTiff(
        bytes.subarray(0, Math.min(bytes.length, at + 2 + length)),
        at + 10,
      );
      orientation = exif?.orientation || 1;
      previews = exif?.previews || [];
    }
    // Start of frame: every SOFn except DHT (C4), JPG (C8) and DAC (CC).
    if (
      marker >= 0xc0 &&
      marker <= 0xcf &&
      ![0xc4, 0xc8, 0xcc].includes(marker)
    )
      return {
        width: (bytes[at + 7] << 8) | bytes[at + 8],
        height: (bytes[at + 5] << 8) | bytes[at + 6],
        orientation,
        previews,
      };
    if (marker === 0xda || length < 2) return null;
    at += 2 + length;
  }
  return null;
}

// Where a container gives no length, a candidate runs to the end of the file; the
// decoder stops at the JPEG end marker.
function jpegMarkers(bytes, fileSize) {
  const previews = [];
  for (let at = 0; at + 3 < bytes.length && previews.length < 6; at++)
    if (bytes[at] === 0xff && bytes[at + 1] === 0xd8 && bytes[at + 2] === 0xff)
      previews.push({ offset: at, length: fileSize - at });
  return previews;
}

export function probeImage(bytes, fileSize = bytes.length) {
  const none = {
    format: "other",
    width: 0,
    height: 0,
    orientation: 1,
    previews: [],
  };
  if (bytes.length < 16) return none;
  if (bytes[0] === 0xff && bytes[1] === 0xd8)
    return { ...none, format: "jpeg", ...readJpeg(bytes) };
  if (ascii(bytes, 1, 3) === "PNG") {
    const view = new DataView(bytes.buffer, bytes.byteOffset);
    return {
      ...none,
      format: "png",
      width: view.getUint32(16),
      height: view.getUint32(20),
    };
  }
  if (ascii(bytes, 0, 15) === "FUJIFILMCCD-RAW" && bytes.length >= 92) {
    const view = new DataView(bytes.buffer, bytes.byteOffset);
    return {
      ...none,
      format: "raw",
      previews: [{ offset: view.getUint32(84), length: view.getUint32(88) }],
    };
  }
  const tiff = readTiff(bytes);
  if (tiff) return { ...none, format: "tiff", ...tiff };
  const cmt1 = ascii(bytes, 0, Math.min(bytes.length, 4096)).indexOf("CMT1");
  return {
    ...none,
    format: "raw",
    orientation: cmt1 >= 0 ? readTiff(bytes, cmt1 + 4)?.orientation || 1 : 1,
    previews: jpegMarkers(bytes, fileSize),
  };
}

// The JPEG preview's own size, read from its first bytes.
export const jpegSize = (bytes) => readJpeg(bytes);

export function validPreviews(previews, fileSize) {
  return previews.filter(
    ({ offset, length }) =>
      offset > 0 && length > 64 && offset + length <= fileSize,
  );
}
