import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit } from "../../src/editor-state.js";
import {
  appSetting,
  newPhotoEdit,
  resetAppSettings,
  setAppSetting,
} from "../../src/app-settings.js";

function withStorage(run) {
  const stored = new Map();
  globalThis.localStorage = {
    getItem: (key) => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value),
    removeItem: (key) => stored.delete(key),
  };
  try {
    run();
  } finally {
    delete globalThis.localStorage;
  }
}

test("a new photograph keeps the current film until Settings chooses a starting film", () =>
  withStorage(() => {
    const films = ["gold200", "portra400"];
    assert.equal(newPhotoEdit(defaultEdit("gold200"), films).stock, "gold200");
    setAppSetting("startingFilm", "portra400");
    assert.equal(newPhotoEdit(defaultEdit("gold200"), films).stock, "portra400");
    setAppSetting("startingFilm", "none");
    assert.equal(newPhotoEdit(defaultEdit("gold200"), films).stock, null);
    // A film the library lacks leaves the current one.
    setAppSetting("startingFilm", "gone");
    assert.equal(newPhotoEdit(defaultEdit("gold200"), films).stock, "gold200");
  }));

test("the film model settings seed a new photograph's edit, and reset clears them", () =>
  withStorage(() => {
    assert.deepEqual(newPhotoEdit(defaultEdit("gold200")).profile, {});
    setAppSetting("startingFormat", "135");
    setAppSetting("grainModel", "film");
    setAppSetting("halationModel", "layered");
    setAppSetting("estimatedHalation", true);
    const edit = newPhotoEdit(defaultEdit("gold200"));
    assert.equal(edit.format, "135");
    assert.equal(edit.halationModel, "layered");
    assert.deepEqual(edit.profile, { grainModel: "film", estimatedHalation: true });
    resetAppSettings();
    assert.equal(appSetting("grainModel"), "clump");
    assert.equal(newPhotoEdit(defaultEdit("gold200")).format, null);
  }));
