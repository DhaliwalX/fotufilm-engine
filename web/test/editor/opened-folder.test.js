import test from "node:test";
import assert from "node:assert/strict";
import {
  folderItems,
  stripPath,
  withOpenedFolder,
} from "../../src/editor/opened-folder.js";

const rows = [
  ["IMG_10.jpg", 3, 1],
  ["IMG_9.jpg", 3, 2],
  ["IMG_9.arw", 9, 2],
  ["clip.mov", 20, 3],
];

test("one photo opens with its folder, in name order, itself shown", () => {
  assert.deepEqual(folderItems("/Shoots/Roll 7/IMG_9.jpg", rows), [
    { path: "/Shoots/Roll 7/clip.mov", name: "clip.mov", shown: false },
    { path: "/Shoots/Roll 7/IMG_9.arw", name: "IMG_9.arw", shown: false },
    { path: "/Shoots/Roll 7/IMG_9.jpg", name: "IMG_9.jpg", shown: true },
    { path: "/Shoots/Roll 7/IMG_10.jpg", name: "IMG_10.jpg", shown: false },
  ]);
});

test("a file its folder does not list opens alone", () => {
  assert.deepEqual(folderItems("/Shoots/notes.json", rows), [
    { path: "/Shoots/notes.json", name: "notes.json", shown: true },
  ]);
});

test("only one photograph, opened where the host lists folders, brings its folder", async () => {
  const listed = [];
  const backend = {
    listOpenedFolder: async (path) => {
      listed.push(path);
      return rows;
    },
  };
  const one = [{ path: "/Shoots/IMG_10.jpg", name: "IMG_10.jpg" }];
  assert.equal((await withOpenedFolder(backend, one)).length, 4);
  const two = [...one, { path: "/Shoots/IMG_9.jpg", name: "IMG_9.jpg" }];
  assert.equal(await withOpenedFolder(backend, two), two);
  const pack = [
    { path: "/Downloads/Kodak.fotufilmpack", name: "Kodak.fotufilmpack" },
  ];
  assert.equal(await withOpenedFolder(backend, pack), pack);
  assert.equal(await withOpenedFolder({}, one), one);
  assert.deepEqual(listed, ["/Shoots/IMG_10.jpg"]);
  // A folder that cannot be read opens the file alone.
  const refusing = {
    listOpenedFolder: async () => Promise.reject(new Error("no")),
  };
  assert.equal(await withOpenedFolder(refusing, one), one);
});

test("the strip names where the photo shown came from", () => {
  const opened = (path) => ({ name: path.split("/").pop(), source: { path } });
  assert.equal(
    stripPath(opened("/Users/license-test/Pictures/Roll 7/frame 2.jpg")),
    "~/Pictures/Roll 7/frame 2.jpg",
  );
  assert.equal(stripPath(opened("/home/license-test/Roll/a.jpg")), "~/Roll/a.jpg");
  assert.equal(
    stripPath(opened("/Volumes/Data/Roll/a.jpg")),
    "/Volumes/Data/Roll/a.jpg",
  );
  const library = {
    name: "b.jpg",
    source: { file: { hostPath: "/Volumes/Card/b.jpg" } },
  };
  assert.equal(stripPath(library), "/Volumes/Card/b.jpg");
  // A browser never learns a file's path: its name stands in.
  assert.equal(stripPath({ name: "c.jpg", source: { file: {} } }), "c.jpg");
});
