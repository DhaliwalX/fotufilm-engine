import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit } from "../../src/editor-state.js";
import {
  DEFAULT_SECTIONS,
  PHOTO_KEYS,
  SETTINGS_SECTIONS,
  copySettings,
  importPresets,
  pasteSettings,
  pasteTitle,
  savePreset,
  sectionOf,
} from "../../src/edit-settings.js";

const base = defaultEdit("gold200");
const source = {
  ...base,
  stock: "portra400",
  format: "still120",
  medium: "endura-premier",
  printFrame: "film",
  filters: ["uv"],
  rotation: 1,
  seed: 7,
  params: {
    ...base.params,
    ev: 1,
    temperature: 5000,
    gradeShadowsWarmth: 0.3,
    grain: 1.4,
  },
  profile: { halation: 0.4, push: 1, enlarger: "condenser" },
};

test("every key of an edit belongs to a section or to the photograph", () => {
  const sections = new Set(SETTINGS_SECTIONS.map((s) => s.id));
  for (const key of [
    ...Object.keys(base).filter((key) => key !== "params" && key !== "profile"),
    ...Object.keys(base.params),
  ])
    if (!PHOTO_KEYS.includes(key)) assert.ok(sections.has(sectionOf(key)), key);
});

test("a field no section names stays behind", () => {
  const stale = { ...source, profile: { ...source.profile, retired: 3 } };
  const pasted = pasteSettings(base, copySettings(stale, DEFAULT_SECTIONS));
  assert.equal(pasted.profile.retired, undefined);
  assert.equal(pasted.profile.halation, 0.4);
});

test("the default sections carry the look and leave the framing", () => {
  const pasted = pasteSettings(base, copySettings(source, DEFAULT_SECTIONS));
  assert.equal(pasted.stock, "portra400");
  assert.equal(pasted.format, "still120");
  assert.equal(pasted.medium, "endura-premier");
  assert.deepEqual(pasted.filters, ["uv"]);
  assert.equal(pasted.params.ev, 1);
  assert.equal(pasted.params.gradeShadowsWarmth, 0.3);
  assert.deepEqual(pasted.profile, source.profile);
  assert.equal(pasted.rotation, 0);
  assert.equal(pasted.seed, 0);
  assert.deepEqual(pasted.video, base.video);
});

test("only the chosen sections move", () => {
  const target = { ...base, profile: { halation: 0.2, bleach: 0.5 } };
  const pasted = pasteSettings(
    target,
    copySettings(source, ["lightExposure", "filmHalation"]),
  );
  assert.equal(pasted.params.ev, 1);
  assert.equal(pasted.params.temperature, base.params.temperature);
  assert.equal(pasted.params.grain, base.params.grain);
  assert.equal(pasted.stock, "gold200");
  // Halation is replaced whole; Lab stays with the photograph.
  assert.deepEqual(pasted.profile, { bleach: 0.5, halation: 0.4 });
});

test("a section the source left at rest resets it here", () => {
  const target = { ...base, profile: { halation: 0.2 } };
  const pasted = pasteSettings(target, copySettings(base, ["filmHalation"]));
  assert.deepEqual(pasted.profile, {});
});

test("geometry travels when chosen", () => {
  const pasted = pasteSettings(base, copySettings(source, ["frameGeometry"]));
  assert.equal(pasted.rotation, 1);
  assert.equal(pasted.stock, "gold200");
});

test("Paste Settings is named for several chosen photos", () => {
  assert.equal(pasteTitle(1), "Paste Settings");
  assert.equal(pasteTitle(3), "Paste Settings to 3 Photos");
});

test("imported presets never replace one already here", (t) => {
  const kept = new Map();
  globalThis.localStorage = {
    getItem: (key) => kept.get(key) ?? null,
    setItem: (key, value) => kept.set(key, value),
  };
  t.after(() => delete globalThis.localStorage);
  const warm = copySettings(source, DEFAULT_SECTIONS);
  const cool = copySettings({ ...source, stock: "gold200" }, DEFAULT_SECTIONS);
  savePreset("Warm", warm);
  assert.equal(importPresets([{ name: "Warm", settings: warm }]), 0);
  assert.equal(
    importPresets([
      { name: "Warm", settings: cool },
      { name: "Cool", settings: cool },
    ]),
    2,
  );
  assert.equal(importPresets([{ name: "Warm", settings: cool }]), 0);
  const { presets } = JSON.parse(kept.get("fotufilm.editPresets"));
  assert.deepEqual(
    presets.map((p) => [p.name, p.settings.edit.stock]),
    [
      ["Cool", "gold200"],
      ["Warm", "portra400"],
      ["Warm 2", "gold200"],
    ],
  );
});
