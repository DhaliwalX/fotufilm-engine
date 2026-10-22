// A 10-bit Cineon DPX file, as `CineonDPX` writes it natively: SMPTE 268M v2.0, big-endian, one
// RGB element whose transfer and colorimetry are printing density, three components packed to a
// 32-bit word (method A, two pad bits at the bottom). What a film scanner hands a grading suite,
// and what DaVinci Resolve reads as Cineon Film Log.

export const DPX_TYPE = "image/x-dpx";

const IMAGE_OFFSET = 2048;
const DENSITY_PER_CODE_VALUE = 0.002;

function text(bytes, value, offset, length) {
  const encoded = new TextEncoder().encode(value).subarray(0, length - 1);
  bytes.set(encoded, offset);
}

function dpxDate(date) {
  const pad = (n) => String(n).padStart(2, "0");
  const minutes = -date.getTimezoneOffset();
  const sign = minutes < 0 ? "-" : "+";
  return (
    `${date.getFullYear()}:${pad(date.getMonth() + 1)}:${pad(date.getDate())}:` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
    `${sign}${pad(Math.floor(Math.abs(minutes) / 60))}${pad(Math.abs(minutes) % 60)}`
  );
}

/// Encodes RGBA code values as a DPX file. `pixels` holds normalised signals (code value / 1023)
/// at `scale` per unit — 65535 for a 16-bit render, 1 for floats — four components a pixel.
export function encodeDPX({
  pixels,
  width,
  height,
  scale = 65535,
  format,
  stock,
  frameRate,
  creator = "Fotufilm",
  date = new Date(),
}) {
  if (!(width > 0 && height > 0)) throw new Error("A DPX needs a picture.");
  if (pixels.length < width * height * 4) throw new Error("The DPX is missing pixels.");
  const imageBytes = width * height * 4;
  const buffer = new ArrayBuffer(IMAGE_OFFSET + imageBytes);
  const bytes = new Uint8Array(buffer);
  const view = new DataView(buffer);
  const u32 = (value, offset) => view.setUint32(offset, value >>> 0, false);
  const u16 = (value, offset) => view.setUint16(offset, value, false);
  const f32 = (value, offset) => view.setFloat32(offset, value, false);
  // Undefined numeric fields are all ones, as the standard asks; text stays zeroed.
  const undefinedRange = (start, end) => bytes.fill(0xff, start, end);

  // File information header, 0..<768.
  u32(0x53445058, 0); // "SDPX": big-endian
  u32(IMAGE_OFFSET, 4);
  text(bytes, "V2.0", 8, 8);
  u32(IMAGE_OFFSET + imageBytes, 16);
  u32(1, 20); // ditto key: a new frame
  u32(1664, 24); // generic header: file, image and orientation
  u32(384, 28); // industry header: film and television
  u32(0, 32); // no user data
  text(bytes, dpxDate(date), 136, 24);
  text(bytes, creator, 160, 100);
  undefinedRange(660, 664); // no encryption key

  // Image information header, 768..<1408.
  u16(0, 768); // left to right, top to bottom
  u16(1, 770);
  u32(width, 772);
  u32(height, 776);
  const element = 780;
  u32(0, element); // unsigned
  u32(0, element + 4); // reference low data code
  f32(0, element + 8);
  u32(1023, element + 12); // reference high data code
  f32(1023 * DENSITY_PER_CODE_VALUE, element + 16);
  bytes[element + 20] = 50; // RGB
  bytes[element + 21] = 1; // transfer: printing density
  bytes[element + 22] = 1; // colorimetric: printing density
  bytes[element + 23] = 10;
  u16(1, element + 24); // filled, method A
  u16(0, element + 26); // no run-length encoding
  u32(IMAGE_OFFSET, element + 28);
  u32(0, element + 32);
  u32(0, element + 36);
  text(bytes, "Cineon log, printing density", element + 40, 32);
  undefinedRange(element + 72, element + 8 * 72); // the seven unused element slots

  // Orientation header, 1408..<1664: no offsets, centres or source sizes are known.
  undefinedRange(1408, 1432);
  undefinedRange(1620, 1636); // border validity and pixel aspect ratio
  u32(1, 1628);
  u32(1, 1632); // square pixels
  undefinedRange(1636, 1644); // scanned size

  // Film information header, 1664..<1920.
  if (format) text(bytes, format, 1680, 32);
  undefinedRange(1712, 1724); // frame position, sequence length, held count
  if (frameRate > 0) f32(frameRate, 1724);
  else undefinedRange(1724, 1728);
  undefinedRange(1728, 1732); // shutter angle
  if (stock) text(bytes, stock, 1732, 32);

  // Television information header, 1920..<2048: nothing applies to a film scan.
  undefinedRange(1920, 1976);

  // Image data: R, G and B in bits 31-22, 21-12 and 11-2 of each word.
  const code = (value) => {
    const cv = Math.round((value / scale) * 1023);
    return Number.isFinite(cv) ? Math.min(Math.max(cv, 0), 1023) : 0;
  };
  for (let i = 0; i < width * height; ++i) {
    const word =
      (code(pixels[i * 4]) << 22) |
      (code(pixels[i * 4 + 1]) << 12) |
      (code(pixels[i * 4 + 2]) << 2);
    u32(word, IMAGE_OFFSET + i * 4);
  }
  return new Blob([buffer], { type: DPX_TYPE });
}
