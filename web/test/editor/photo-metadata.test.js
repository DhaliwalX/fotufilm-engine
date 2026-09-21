import test from "node:test";
import assert from "node:assert/strict";
import { readPhotoMetadata } from "../../src/photo-metadata.js";
import { makeDNG } from "./raw-fixture.js";
import { captureTags, lensShot, lensOpcodes } from "./lens-fixture.js";
const fixture = () =>
  makeDNG({
    width: 320,
    height: 192,
    extraTags: [
      ...captureTags,
      [50829, 4, [0, 0, 192, 320]],
      [50720, 4, [300, 180]],
      [51022, 7, lensOpcodes()],
    ],
  });

test("DNG capture tags and a compact TIFF carry lens metadata without sensor pixels", async () => {
  const bytes = fixture(),
    reads = [];
  const blob = new Blob([bytes]);
  const metadata = await readPhotoMetadata({
    size: blob.size,
    slice: (at, end) => {
      reads.push([at, end]);
      return blob.slice(at, end);
    },
  });
  assert.deepEqual(metadata.shot, lensShot);
  const stripped = Buffer.from(metadata.embeddedTIFF, "base64");
  assert.ok(stripped.length < 1024);
  assert.ok(reads.reduce((sum, [a, b]) => sum + b - a, 0) < 2048);
  const parsed = await readPhotoMetadata(new Blob([stripped]));
  assert.equal(parsed.embeddedTIFF, metadata.embeddedTIFF);
  assert.equal(parsed.shot, null);
});

test("JPEG, PNG and WebP Exif containers locate the same TIFF capture metadata", async () => {
  // A TIFF with its sensor payload removed is sufficient for metadata extraction.
  const bytes = fixture().subarray(0, 4096);
  const jpeg = new Uint8Array(bytes.length + 14),
    j = new DataView(jpeg.buffer);
  jpeg.set([255, 216, 255, 225]);
  j.setUint16(4, bytes.length + 8);
  jpeg.set([69, 120, 105, 102, 0, 0], 6);
  jpeg.set(bytes, 12);
  jpeg.set([255, 217], jpeg.length - 2);
  const png = new Uint8Array(bytes.length + 20),
    p = new DataView(png.buffer);
  png.set([137, 80, 78, 71, 13, 10, 26, 10]);
  p.setUint32(8, bytes.length);
  png.set([101, 88, 73, 102], 12);
  png.set(bytes, 16);
  const webp = new Uint8Array(bytes.length + 20),
    w = new DataView(webp.buffer);
  webp.set(new TextEncoder().encode("RIFF"), 0);
  w.setUint32(4, webp.length - 8, true);
  webp.set(new TextEncoder().encode("WEBPEXIF"), 8);
  w.setUint32(16, bytes.length, true);
  webp.set(bytes, 20);
  for (const container of [jpeg, png, webp])
    assert.deepEqual(
      (await readPhotoMetadata(new Blob([container]))).shot,
      lensShot,
    );
});

test("corrupt optional metadata cannot block import or escape bounds; cancellation is honored", async () => {
  const bytes = fixture(),
    view = new DataView(bytes.buffer);
  view.setUint32(4, 0xfffffff0, true);
  assert.match(
    (await readPhotoMetadata(new Blob([bytes]))).warning,
    /could not be read/,
  );
  assert.deepEqual(await readPhotoMetadata(new Blob([new Uint8Array(12)])), {});
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    () =>
      readPhotoMetadata(new Blob([fixture()]), { signal: controller.signal }),
    { name: "AbortError" },
  );
});

test("big-endian TIFF capture and lens tags retain their byte order", async () => {
  const bytes = makeDNG({
    littleEndian: false,
    extraTags: [...captureTags, [51022, 7, lensOpcodes()]],
  });
  const metadata = await readPhotoMetadata(new Blob([bytes]));
  assert.deepEqual(metadata.shot, lensShot);
  const stripped = Buffer.from(metadata.embeddedTIFF, "base64");
  assert.equal(stripped.subarray(0, 2).toString(), "MM");
  assert.equal(
    (await readPhotoMetadata(new Blob([stripped]))).embeddedTIFF,
    metadata.embeddedTIFF,
  );
});
