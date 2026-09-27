import test from "node:test";
import assert from "node:assert/strict";
import { historyReducer, initialHistory, defaultEdit } from "../../src/editor-state.js";
import { appSetting, setAppSetting, APP_SETTINGS } from "../../src/app-settings.js";

test("a suggested film replaces the photograph's film without an undo step", () => {
  const start = { ...initialHistory, present: defaultEdit("gold200") };
  const next = historyReducer(start, { type: "replace", patch: { stock: "portra400" } });
  assert.equal(next.present.stock, "portra400");
  assert.equal(next.past.length, 0);
});

test("app settings fall back to their defaults and keep what is set", () => {
  const stored = new Map();
  globalThis.localStorage = {
    getItem: (key) => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value),
  };
  try {
    assert.equal(appSetting("autoFilm"), APP_SETTINGS.autoFilm);
    setAppSetting("autoFilm", true);
    assert.equal(appSetting("autoFilm"), true);
    assert.throws(() => setAppSetting("nothing", 1), /Unknown setting/);
  } finally {
    delete globalThis.localStorage;
  }
});
