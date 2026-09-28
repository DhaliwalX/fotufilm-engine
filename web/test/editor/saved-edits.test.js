import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit } from "../../src/editor-state.js";
import {
  editStore,
  editText,
  fileIdentity,
  findSavedEdit,
} from "../../src/saved-edits.js";

const stocks = [{ id: "gold200", name: "Gold 200", available: [] }];
const memoryStore = (entries = {}) => {
  const kept = new Map(Object.entries(entries));
  return {
    kept,
    load: async (key) => kept.get(key) ?? null,
    save: async (key, text) => (text == null ? kept.delete(key) : kept.set(key, text)),
  };
};

test("a still is known by its contents, as the Mac app knows it; a movie by name, size and date", async () => {
  const still = new File(["abc"], "a.jpg", { type: "image/jpeg", lastModified: 5 });
  const renamed = new File(["abc"], "b.jpg", { type: "image/jpeg", lastModified: 9 });
  const expected = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  assert.equal(await fileIdentity(still), expected);
  assert.equal(await fileIdentity(renamed), expected);
  const movie = new File(["abc"], "clip.mov", { type: "video/quicktime", lastModified: 7 });
  assert.equal(await fileIdentity(movie), "file:clip.mov|3|7");
  assert.equal(await fileIdentity(null), null);
});

test("a file opened again starts from the edit it was left with", async () => {
  const edit = { ...defaultEdit("gold200"), rotation: 1 };
  const file = new File(["pixels"], "a.jpg", { type: "image/jpeg" });
  const key = await fileIdentity(file);
  const store = memoryStore({ [key]: editText(edit) });
  const found = await findSavedEdit(store, stocks, { file });
  assert.equal(found.editKey, key);
  assert.equal(found.savedEdit.rotation, 1);
  assert.equal(found.problem, undefined);
  // A file the host opened comes with the identity it answered; a library photo with its key.
  const hosted = await findSavedEdit(memoryStore({ "sha256:x": editText(edit) }), stocks, {
    identity: "sha256:x",
  });
  assert.equal(hosted.savedEdit.rotation, 1);
  const library = await findSavedEdit(memoryStore(), stocks, { editKey: "folder/a.jpg", file });
  assert.deepEqual(library, { editKey: "folder/a.jpg", savedEdit: null });
});

test("an edit that no longer fits is reported and the photograph opens fresh", async () => {
  const gone = { ...defaultEdit("retired"), rotation: 1 };
  const store = memoryStore({ "sha256:y": editText(gone) });
  const found = await findSavedEdit(store, stocks, { identity: "sha256:y" });
  assert.equal(found.savedEdit, null);
  assert.match(found.problem, /not restored.*not installed/);
  // A store that cannot be read never stops a file opening.
  const broken = { load: () => { throw new Error("no disk"); }, save() {} };
  assert.deepEqual(await findSavedEdit(broken, stocks, { identity: "sha256:y" }), {
    editKey: "sha256:y",
    savedEdit: null,
  });
  assert.deepEqual(await findSavedEdit(store, stocks, {}), { editKey: null, savedEdit: null });
});

test("a backend that keeps edits itself replaces the device store", () => {
  const device = memoryStore();
  assert.equal(editStore({}, device), device);
  const host = { loadEdit: async () => null, saveEdit: async () => {} };
  const store = editStore(host, device);
  assert.equal(store.load, host.loadEdit);
  assert.equal(store.save, host.saveEdit);
  assert.equal(editStore({ loadEdit: host.loadEdit }, device), device);
});
