import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit } from "../../src/editor-state.js";
import { DEFAULT_SECTIONS, copySettings } from "../../src/edit-settings.js";
import {
  isLookFile,
  lookFileName,
  lookText,
  readLooks,
} from "../../src/look-files.js";

const stocks = [
  { id: "gold200", name: "Gold 200", available: [] },
  { id: "portra400", name: "Portra 400", available: [] },
];
const base = defaultEdit("portra400");
const edit = {
  ...base,
  seed: 42,
  rotation: 1,
  negative: null,
  video: { ...base.video, trimStart: 3 },
  params: { ...base.params, ev: 1, grain: 1.4 },
  profile: { halation: 0.4 },
};
const preset = (name, from = edit) => ({
  id: name,
  name,
  settings: copySettings(from, DEFAULT_SECTIONS),
});

test("a look file reads back as the presets it holds", () => {
  const { presets, missing } = readLooks(
    lookText([preset("Warm"), preset("Cool")]),
    stocks,
  );
  assert.deepEqual(missing, []);
  assert.deepEqual(
    presets.map((p) => p.name),
    ["Warm", "Cool"],
  );
  assert.deepEqual(presets[0].settings.sections, DEFAULT_SECTIONS);
  assert.equal(presets[0].settings.edit.stock, "portra400");
  assert.equal(presets[0].settings.edit.params.ev, 1);
  assert.deepEqual(presets[0].settings.edit.profile, { halation: 0.4 });
});

test("a look leaves the photograph's own behind", () => {
  const written = JSON.parse(lookText([preset("Warm")]));
  const shared = written.presets[0].settings.edit;
  assert.equal(shared.seed, 0);
  assert.deepEqual(shared.video, base.video);
  assert.equal(shared.negative, null);
  assert.equal(written.presets[0].id, undefined);
});

test("a look on a film not installed is kept and named", () => {
  const { presets, missing } = readLooks(lookText([preset("Warm")]), [
    stocks[0],
  ]);
  assert.equal(presets.length, 1);
  assert.deepEqual(missing, [{ name: "Warm", film: "portra400" }]);
});

test("sections a later version adds are left out", () => {
  const file = JSON.parse(lookText([preset("Warm")]));
  file.presets[0].settings.sections.push("hologram");
  const { presets } = readLooks(JSON.stringify(file), stocks);
  assert.deepEqual(presets[0].settings.sections, DEFAULT_SECTIONS);
});

test("files that are not looks are refused with a reason", () => {
  assert.throws(() => readLooks("not json", stocks), /not a Fotufilm look/);
  assert.throws(
    () => readLooks(JSON.stringify({ version: 1, edit: base }), stocks),
    /not a Fotufilm look/,
  );
  const newer = JSON.parse(lookText([preset("Warm")]));
  newer.version = 2;
  assert.throws(
    () => readLooks(JSON.stringify(newer), stocks),
    /newer version/,
  );
  const empty = JSON.parse(lookText([]));
  assert.throws(
    () => readLooks(JSON.stringify(empty), stocks),
    /holds no presets/,
  );
  const damaged = JSON.parse(lookText([preset("Warm")]));
  damaged.presets[0].settings.edit.params.ev = 99;
  assert.throws(
    () => readLooks(JSON.stringify(damaged), stocks),
    /“Warm” could not be read/,
  );
  const unnamed = JSON.parse(lookText([preset("Warm")]));
  unnamed.presets[0].name = " ";
  assert.throws(() => readLooks(JSON.stringify(unnamed), stocks), /damaged/);
});

test("a look file is named for its preset", () => {
  assert.equal(
    lookFileName([preset("Portra / warm: v1.2")]),
    "Portra warm v1.2.fotufilmlook",
  );
  assert.equal(lookFileName([preset("..")]), "Fotufilm Presets.fotufilmlook");
  assert.equal(
    lookFileName([preset("A"), preset("B")]),
    "Fotufilm Presets.fotufilmlook",
  );
  assert.ok(isLookFile("Warm.FotufilmLook"));
  assert.ok(!isLookFile("Warm.json"));
});
