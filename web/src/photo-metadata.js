// Read only capture/lens tags. Pixel strips, thumbnails, maker-note blobs and GPS
// directories are never copied to the profile worker or persisted with a lens catalogue.
const sizes = {
  1: 1,
  2: 1,
  3: 2,
  4: 4,
  5: 8,
  6: 1,
  7: 1,
  8: 2,
  9: 4,
  10: 8,
  11: 4,
  12: 8,
};
const lensTags = new Set([254, 50719, 50720, 50829, 51009, 51022]);
const captureTags = new Set([271, 272, 33437, 37386, 42035, 42036]);
const wanted = new Set([...lensTags, ...captureTags, 274, 330, 34665]);
const limit = 1024 * 1024;

function base64(bytes) {
  let text = "";
  for (let i = 0; i < bytes.length; i += 8192)
    text += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(text);
}

// Retain the original TIFF byte order and raw tag values. The native DNG reader
// owns opcode interpretation, refusal rules and active-area/crop normalization.
function compactTIFF(entries, little) {
  const kept = [...entries.values()].filter((entry) => lensTags.has(entry.tag));
  let size = 8 + 2 + kept.length * 12 + 4;
  for (const entry of kept)
    if (entry.bytes.length > 4) size += (entry.bytes.length + 3) & ~3;
  if (size > limit) throw new Error("Lens metadata is too large.");
  const bytes = new Uint8Array(size),
    view = new DataView(bytes.buffer);
  bytes.set(little ? [73, 73] : [77, 77]);
  view.setUint16(2, 42, little);
  view.setUint32(4, 8, little);
  view.setUint16(8, kept.length, little);
  let next = 8 + 2 + kept.length * 12 + 4;
  kept.forEach((entry, i) => {
    const at = 10 + i * 12;
    view.setUint16(at, entry.tag, little);
    view.setUint16(at + 2, entry.type, little);
    view.setUint32(at + 4, entry.count, little);
    if (entry.bytes.length <= 4) bytes.set(entry.bytes, at + 8);
    else {
      view.setUint32(at + 8, next, little);
      bytes.set(entry.bytes, next);
      next += (entry.bytes.length + 3) & ~3;
    }
  });
  return base64(bytes);
}

export async function readPhotoMetadata(file, { signal } = {}) {
  let consumed = 0;
  async function read(at, length) {
    if (signal?.aborted)
      throw new DOMException("Import cancelled.", "AbortError");
    if (
      !Number.isSafeInteger(at) ||
      !Number.isSafeInteger(length) ||
      at < 0 ||
      length < 0 ||
      at + length > file.size ||
      consumed + length > limit
    )
      throw new Error("Invalid or oversized lens metadata.");
    consumed += length;
    return new Uint8Array(await file.slice(at, at + length).arrayBuffer());
  }
  try {
    const header = await read(0, Math.min(file.size, 12));
    if (header.length < 8) return {};
    const text = (bytes) => new TextDecoder().decode(bytes);
    let base = 0,
      end = file.size;
    if (header[0] === 0xff && header[1] === 0xd8) {
      base = null;
      for (let at = 2, count = 0; count < 512 && at + 4 <= file.size; count++) {
        const marker = await read(at, 4);
        if (marker[0] !== 0xff || marker[1] === 0xda || marker[1] === 0xd9)
          break;
        if (marker[1] === 0xff) {
          at++;
          continue;
        }
        const length = marker[2] * 256 + marker[3];
        if (length < 2 || at + 2 + length > file.size) break;
        if (
          marker[1] === 0xe1 &&
          length >= 8 &&
          text(await read(at + 4, 6)) === "Exif\0\0"
        ) {
          base = at + 10;
          end = at + 2 + length;
          break;
        }
        at += length + 2;
      }
    } else if (header[0] === 137 && text(header.subarray(1, 4)) === "PNG") {
      base = null;
      for (
        let at = 8, count = 0;
        count < 512 && at + 12 <= file.size;
        count++
      ) {
        const chunk = await read(at, 8),
          view = new DataView(chunk.buffer);
        const length = view.getUint32(0),
          kind = text(chunk.subarray(4));
        if (at + length + 12 > file.size) break;
        if (kind === "eXIf") {
          base = at + 8;
          end = base + length;
          break;
        }
        if (kind === "IEND") break;
        at += length + 12;
      }
    } else if (
      text(header.subarray(0, 4)) === "RIFF" &&
      text(header.subarray(8, 12)) === "WEBP"
    ) {
      base = null;
      for (
        let at = 12, count = 0;
        count < 512 && at + 8 <= file.size;
        count++
      ) {
        const chunk = await read(at, 8),
          length = new DataView(chunk.buffer).getUint32(4, true);
        if (at + length + 8 > file.size) break;
        if (text(chunk.subarray(0, 4)) === "EXIF") {
          base = at + 8;
          end = base + length;
          if (length >= 6 && text(await read(base, 6)) === "Exif\0\0")
            base += 6;
          break;
        }
        at += 8 + length + (length % 2);
      }
    }
    if (base == null || end - base < 8) return {};
    const tiffRead = (at, length) => {
      if (at < 0 || at + length > end - base)
        throw new Error("Invalid lens metadata offset.");
      return read(base + at, length);
    };
    const tiff = await tiffRead(0, 8),
      little = tiff[0] === 73 && tiff[1] === 73;
    if (!little && !(tiff[0] === 77 && tiff[1] === 77)) return {};
    const head = new DataView(tiff.buffer);
    if (head.getUint16(2, little) !== 42) return {};
    const numbers = (entry) => {
      if (!entry) return [];
      const view = new DataView(
          entry.bytes.buffer,
          entry.bytes.byteOffset,
          entry.bytes.byteLength,
        ),
        values = [];
      for (let i = 0; i < Math.min(entry.count, 16); i++) {
        const at = i * sizes[entry.type];
        if (entry.type === 3) values.push(view.getUint16(at, little));
        else if (entry.type === 4) values.push(view.getUint32(at, little));
        else if (entry.type === 5)
          values.push(
            view.getUint32(at, little) / view.getUint32(at + 4, little),
          );
      }
      return values;
    };
    const visited = new Set();
    async function directory(offset) {
      if (offset < 8 || visited.has(offset)) return new Map();
      visited.add(offset);
      const count = new DataView((await tiffRead(offset, 2)).buffer).getUint16(
        0,
        little,
      );
      if (!count || count > 4096) return new Map();
      const entries = new Map(),
        raw = await tiffRead(offset + 2, count * 12),
        view = new DataView(raw.buffer);
      for (let i = 0; i < count; i++) {
        const at = i * 12,
          tag = view.getUint16(at, little),
          type = view.getUint16(at + 2, little),
          count = view.getUint32(at + 4, little);
        if (!wanted.has(tag) || !sizes[type] || !count) continue;
        const length = count * sizes[type],
          value =
            length <= 4
              ? raw.slice(at + 8, at + 8 + length)
              : await tiffRead(view.getUint32(at + 8, little), length);
        entries.set(tag, { tag, type, count, bytes: value });
      }
      return entries;
    }
    const root = await directory(head.getUint32(4, little)),
      candidates = [root];
    for (const offset of numbers(root.get(330)))
      candidates.push(await directory(offset));
    const exif = await directory(numbers(root.get(34665))[0] || 0);
    const capture = new Map([...root, ...exif]);
    const string = (tag) =>
      capture.get(tag)?.type === 2
        ? text(capture.get(tag).bytes).split("\0")[0].trim().slice(0, 512)
        : null;
    const positive = (tag) => {
      const value = numbers(capture.get(tag))[0];
      return Number.isFinite(value) && value > 0 ? value : null;
    };
    const lensModel = string(42036);
    const shot = lensModel
      ? {
          lensModel,
          lensMaker: string(42035),
          cameraModel: string(272),
          focalLength: positive(37386),
          aperture: positive(33437),
        }
      : null;
    const carrying = candidates.filter(
      (entries) => entries.has(51009) || entries.has(51022),
    );
    const selected =
      carrying.find((entries) => numbers(entries.get(254))[0] === 0) ||
      carrying[0];
    return {
      shot,
      orientation: numbers(root.get(274))[0] || 1,
      embeddedTIFF: selected ? compactTIFF(selected, little) : null,
    };
  } catch (error) {
    if (error.name === "AbortError") throw error;
    // A damaged optional tag must not prevent opening an otherwise valid photo.
    return {
      warning:
        "The file’s lens metadata could not be read. Use a measured profile or the manual sliders.",
    };
  }
}
