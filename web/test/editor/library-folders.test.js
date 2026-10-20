import test from "node:test";
import assert from "node:assert/strict";
import {
  jpegSize,
  probeImage,
  validPreviews,
} from "../../src/photo-library/image-probe.js";
import {
  parseFolderPath,
  uploadedFiles,
  walkDirectory,
} from "../../src/photo-library/browser-folders.js";
import { thumbnailSize } from "../../src/photo-library/thumbnail-resampler.js";
import { libraryMediaKind } from "../../src/media-types.js";

test("library media is recognised by extension", () => {
  assert.equal(libraryMediaKind("A.JPG"), "image");
  assert.equal(libraryMediaKind("b.cr3"), "raw");
  assert.equal(libraryMediaKind("c.MOV"), "video");
  assert.equal(libraryMediaKind("notes.txt"), null);
});

function tiff(entries, { little = true, extra = [] } = {}) {
  // IFD0 at 8, then the tag data regions described by `extra`.
  const size = 8 + 2 + entries.length * 12 + 4;
  const bytes = new Uint8Array(4096);
  const view = new DataView(bytes.buffer);
  bytes.set(little ? [0x49, 0x49] : [0x4d, 0x4d]);
  view.setUint16(2, 42, little);
  view.setUint32(4, 8, little);
  view.setUint16(8, entries.length, little);
  entries.forEach(([tag, type, count, value], i) => {
    const at = 10 + i * 12;
    view.setUint16(at, tag, little);
    view.setUint16(at + 2, type, little);
    view.setUint32(at + 4, count, little);
    if (type === 3 && count === 1) view.setUint16(at + 8, value, little);
    else view.setUint32(at + 8, value, little);
  });
  for (const [offset, data] of extra) bytes.set(data, offset);
  assert.ok(size < 512);
  return bytes;
}
const sof = (width, height) => [
  0xff,
  0xd8,
  0xff,
  0xc0,
  0,
  17,
  8,
  height >> 8,
  height & 255,
  width >> 8,
  width & 255,
  3,
];

test("raw probes find embedded previews and the raw's orientation", () => {
  const nef = tiff(
    [
      [0x0112, 3, 1, 6],
      [0x0201, 4, 1, 1024],
      [0x0202, 4, 1, 2000],
    ],
    { extra: [[1024, sof(1620, 1080)]] },
  );
  const probe = probeImage(nef, 4096);
  assert.equal(probe.format, "tiff");
  assert.equal(probe.orientation, 6);
  assert.deepEqual(validPreviews(probe.previews, 4096), [
    { offset: 1024, length: 2000 },
  ]);
  assert.deepEqual(jpegSize(nef.subarray(1024)), {
    width: 1620,
    height: 1080,
    orientation: 1,
    previews: [],
  });

  // A DNG's lossless raw strip (compression 7, CFA photometry) is not a preview.
  const dng = tiff(
    [
      [0x0103, 3, 1, 7],
      [0x0106, 3, 1, 32803],
      [0x0111, 4, 1, 600],
      [0x0117, 4, 1, 900],
    ],
    { little: false },
  );
  assert.deepEqual(probeImage(dng, 4096).previews, []);

  const raf = new Uint8Array(200);
  raf.set([..."FUJIFILMCCD-RAW"].map((c) => c.charCodeAt(0)));
  new DataView(raf.buffer).setUint32(84, 148);
  new DataView(raf.buffer).setUint32(88, 40);
  assert.deepEqual(probeImage(raf, 200).previews, [
    { offset: 148, length: 40 },
  ]);

  // CR3: orientation from the CMT1 TIFF, previews from JPEG start markers.
  const cr3 = new Uint8Array(1200);
  cr3.set(
    [..."ftypcrx CMT1"].map((c) => c.charCodeAt(0)),
    4,
  );
  cr3.set(tiff([[0x0112, 3, 1, 8]]).subarray(0, 64), 16);
  cr3.set([0xff, 0xd8, 0xff, 0xdb], 700);
  const probed = probeImage(cr3, 5000);
  assert.equal(probed.orientation, 8);
  assert.deepEqual(probed.previews, [{ offset: 700, length: 4300 }]);
});

test("JPEG probes read size, EXIF orientation and the EXIF thumbnail", () => {
  // Orientation 3 and a thumbnail 64 bytes into the TIFF (file offset 12 + 64).
  const exif = tiff([
    [0x0112, 3, 1, 3],
    [0x0201, 4, 1, 64],
    [0x0202, 4, 1, 500],
  ]).subarray(0, 64);
  const app1 = [
    0xff,
    0xe1,
    0,
    8 + exif.length,
    ...[..."Exif"].map((c) => c.charCodeAt(0)),
    0,
    0,
  ];
  const jpeg = new Uint8Array([
    0xff,
    0xd8,
    ...app1,
    ...exif,
    ...sof(4000, 3000).slice(2),
  ]);
  assert.deepEqual(
    (({ format, width, height, orientation }) => ({
      format,
      width,
      height,
      orientation,
    }))(probeImage(jpeg)),
    { format: "jpeg", width: 4000, height: 3000, orientation: 3 },
  );
  assert.deepEqual(probeImage(jpeg).previews, [{ offset: 76, length: 500 }]);
});

test("thumbnail sizes keep the long edge and swap for quarter turns", () => {
  assert.deepEqual(thumbnailSize(6000, 4000, 480), [480, 320]);
  assert.deepEqual(thumbnailSize(6000, 4000, 480, 6), [320, 480]);
  assert.deepEqual(thumbnailSize(200, 100, 480), [200, 100]);
});

// A directory handle over {name: size} files; a null size is a file deleted
// after it was listed.
function directory(tree) {
  const file = (name, value) => ({
    kind: "file",
    getFile: async () => {
      if (value === null) throw new DOMException("Gone.", "NotFoundError");
      return { name, size: value, lastModified: value };
    },
  });
  const child = (name, value) =>
    typeof value === "object" && value !== null
      ? directory(value)
      : file(name, value);
  return {
    kind: "directory",
    async *entries() {
      for (const [name, value] of Object.entries(tree))
        yield [name, child(name, value)];
    },
  };
}

test("browser folders walk subfolders and skip hidden and unsupported files", async () => {
  const rows = await walkDirectory(
    directory({
      "a.jpg": 1,
      "gone.jpg": null,
      "notes.txt": 2,
      ".hidden.jpg": 3,
      "._a.jpg": 4,
      day: { "b.ARW": 5, ".cache": { "c.jpg": 6 } },
    }),
  );
  assert.deepEqual(rows.sort(), [
    ["a.jpg", 1, 1],
    ["day/b.ARW", 5, 5],
  ]);
});

test("a browser library folder is named by its id and name, its photos below", () => {
  assert.deepEqual(parseFolderPath("/folders/k3x9/Roll 1/day/a.jpg"), {
    id: "k3x9",
    name: "Roll 1",
    path: "day/a.jpg",
  });
  assert.deepEqual(parseFolderPath("/folders/k3x9/Roll 1"), {
    id: "k3x9",
    name: "Roll 1",
    path: "",
  });
  assert.equal(parseFolderPath("/home/someone/a.jpg"), null);
  assert.equal(parseFolderPath("/folders/k3x9"), null);
});

test("an uploaded folder keeps its photos by their path below it", () => {
  const uploads = uploadedFiles([
    { name: "a.jpg", webkitRelativePath: "Roll 1/a.jpg" },
    { name: "b.mov", webkitRelativePath: "Roll 1/sub/b.mov" },
    { name: "c.jpg", webkitRelativePath: "Roll 1/.trash/c.jpg" },
    { name: "d.txt", webkitRelativePath: "Roll 1/d.txt" },
  ]);
  assert.deepEqual([...uploads.keys()], ["a.jpg", "sub/b.mov"]);
});
