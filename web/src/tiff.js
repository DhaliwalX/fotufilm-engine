import { srgbProfile } from "./srgb-profile.js";

// TIFF 6.0, chunky unsigned RGB, unassociated alpha, lossless uncompressed strips.
// https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf
// No Canvas conversion: samples retain the renderer's full 16-bit precision.
export function encodeTiff16({ pixels, width, height }) {
  if (
    !Number.isSafeInteger(width) ||
    !Number.isSafeInteger(height) ||
    width < 1 ||
    height < 1 ||
    !(pixels instanceof Uint16Array) ||
    pixels.length !== width * height * 4
  )
    throw new Error("Invalid 16-bit TIFF pixels.");
  const rows = Math.min(64, height),
    strips = Math.ceil(height / rows);
  const tags = [
    [256, 4, [width]],
    [257, 4, [height]],
    [258, 3, [16, 16, 16, 16]],
    [259, 3, [1]],
    [262, 3, [2]],
    [273, 4, new Array(strips).fill(0)],
    [274, 3, [1]],
    [277, 3, [4]],
    [278, 4, [rows]],
    [
      279,
      4,
      Array.from(
        { length: strips },
        (_, i) => Math.min(rows, height - i * rows) * width * 8,
      ),
    ],
    [284, 3, [1]],
    [338, 3, [2]],
    [339, 3, [1, 1, 1, 1]],
    [34675, 7, srgbProfile],
  ];
  const sizeOf = (type) => (type === 3 ? 2 : type === 4 ? 4 : 1);
  let size = 8 + 2 + tags.length * 12 + 4;
  for (const tag of tags) {
    const bytes = sizeOf(tag[1]) * tag[2].length;
    if (bytes > 4) {
      tag[3] = size;
      size += (bytes + 1) & ~1;
    }
  }
  if (size + pixels.byteLength >= 0x100000000)
    throw new Error("This TIFF exceeds 4 GB. Choose a smaller export size.");
  const header = new Uint8Array(size),
    view = new DataView(header.buffer);
  header.set([0x49, 0x49]);
  view.setUint16(2, 42, true);
  view.setUint32(4, 8, true);
  view.setUint16(8, tags.length, true);
  let position = size;
  tags[5][2] = tags[9][2].map((bytes) => {
    const offset = position;
    position += bytes;
    return offset;
  });
  tags.forEach(([tag, type, values, offset], i) => {
    const entry = 10 + i * 12;
    view.setUint16(entry, tag, true);
    view.setUint16(entry + 2, type, true);
    view.setUint32(entry + 4, values.length, true);
    if (offset !== undefined) view.setUint32(entry + 8, offset, true);
    let at = offset ?? entry + 8;
    for (const value of values) {
      if (type === 3) view.setUint16(at, value, true);
      else if (type === 4) view.setUint32(at, value, true);
      else view.setUint8(at, value);
      at += sizeOf(type);
    }
  });
  const parts = [header];
  for (let row = 0; row < height; row += rows) {
    const count = Math.min(rows, height - row) * width * 4;
    const bytes = new Uint8Array(count * 2),
      strip = new DataView(bytes.buffer);
    for (let i = 0; i < count; i++)
      strip.setUint16(i * 2, pixels[row * width * 4 + i], true);
    parts.push(bytes);
  }
  return new Blob(parts, { type: "image/tiff" });
}
