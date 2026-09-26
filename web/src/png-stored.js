// Lossless PNG with uncompressed (stored) deflate blocks. Preview frames are shown once and
// discarded, so skipping compression is several times faster than the browser's encoder.
const CRC = new Int32Array(256 * 8);
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  CRC[n] = c;
}
for (let n = 0; n < 256; n++)
  for (let t = 1; t < 8; t++)
    CRC[t * 256 + n] =
      (CRC[(t - 1) * 256 + n] >>> 8) ^ CRC[CRC[(t - 1) * 256 + n] & 255];
function crc32(bytes, start, end, crc = -1) {
  let i = start;
  for (; i + 8 <= end; i += 8) {
    const a =
      crc ^
      (bytes[i] |
        (bytes[i + 1] << 8) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 24));
    crc =
      CRC[1792 + (a & 255)] ^
      CRC[1536 + ((a >>> 8) & 255)] ^
      CRC[1280 + ((a >>> 16) & 255)] ^
      CRC[1024 + (a >>> 24)] ^
      CRC[768 + bytes[i + 4]] ^
      CRC[512 + bytes[i + 5]] ^
      CRC[256 + bytes[i + 6]] ^
      CRC[bytes[i + 7]];
  }
  for (; i < end; i++) crc = CRC[(crc ^ bytes[i]) & 255] ^ (crc >>> 8);
  return crc;
}
const STORED_BLOCK = 65535;
// cICP colour primaries: 1 = BT.709/sRGB, 12 = P3-D65; transfer 13 = sRGB.
const PRIMARIES = { srgb: 1, "display-p3": 12 };
export function storedPng(pixels, width, height, colorSpace = "srgb") {
  const row = width * 3 + 1;
  const raw = row * height;
  const blocks = Math.max(1, Math.ceil(raw / STORED_BLOCK));
  const idat = 2 + raw + blocks * 5 + 4;
  const size = 8 + 25 + 16 + 12 + idat + 12;
  const out = new Uint8Array(size);
  const view = new DataView(out.buffer);
  out.set([137, 80, 78, 71, 13, 10, 26, 10]);
  let at = 8;
  const chunk = (type, length, write) => {
    view.setUint32(at, length);
    for (let i = 0; i < 4; i++) out[at + 4 + i] = type.charCodeAt(i);
    write(at + 8);
    view.setUint32(at + 8 + length, crc32(out, at + 4, at + 8 + length) ^ -1);
    at += 12 + length;
  };
  chunk("IHDR", 13, (p) => {
    view.setUint32(p, width);
    view.setUint32(p + 4, height);
    out.set([8, 2, 0, 0, 0], p + 8);
  });
  chunk("cICP", 4, (p) => out.set([PRIMARIES[colorSpace] ?? 1, 13, 0, 1], p));
  chunk("IDAT", idat, (p) => {
    const rows = new Uint8Array(raw);
    const rgba = new Uint32Array(
      pixels.buffer,
      pixels.byteOffset,
      width * height,
    );
    for (let y = 0, q = 1, i = 0; y < height; y++, q += 1) {
      for (let x = 0; x < width; x++, q += 3) {
        const v = rgba[i++];
        rows[q] = v;
        rows[q + 1] = v >>> 8;
        rows[q + 2] = v >>> 16;
      }
    }
    out[p] = 0x78;
    out[p + 1] = 0x01;
    let q = p + 2;
    for (let start = 0; start < raw || start === 0; start += STORED_BLOCK) {
      const length = Math.min(STORED_BLOCK, raw - start);
      out[q] = start + length >= raw ? 1 : 0;
      view.setUint16(q + 1, length, true);
      view.setUint16(q + 3, ~length & 0xffff, true);
      out.set(rows.subarray(start, start + length), q + 5);
      q += 5 + length;
      if (length === 0) break;
    }
    let s1 = 1,
      s2 = 0;
    for (let i = 0; i < raw; ) {
      const stop = Math.min(raw, i + 5552);
      for (; i < stop; i++) s2 += s1 += rows[i];
      s1 %= 65521;
      s2 %= 65521;
    }
    view.setUint32(q, (s2 << 16) | s1);
  });
  chunk("IEND", 0, () => {});
  return new Blob([out], { type: "image/png" });
}
