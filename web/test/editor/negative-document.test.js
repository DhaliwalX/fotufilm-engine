import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit, parseEdit } from "../../src/editor-state.js";
import { DEFAULT_SECTIONS, copySettings, pastedEdit } from "../../src/edit-settings.js";
import { editText } from "../../src/saved-edits.js";
import { inspectorPanels } from "../../src/editor-catalogue.js";
import {
  ROLL_PANEL,
  documentPanels,
  negativeStartingStock,
  newNegative,
  parseNegative,
  rollDocuments,
  rollOf,
} from "../../src/negative-document.js";

const stock = (id, readsNegative) => ({
  id,
  name: id,
  readsNegative,
  media: [{ id: "screen" }],
  available: [],
});
const stocks = [stock("e100", false), stock("gold200", true), stock("portra400", true)];
const scan = (...ids) => ({
  negative: { suggestions: ids.map((id) => ({ films: [{ id, name: id }], likelihood: 0.5 })) },
});
const negativeEdit = (stockID, negative = newNegative()) => ({
  ...defaultEdit(stockID),
  negative,
});

test("a negative opens on the first film its base looks like that can read it", () => {
  assert.equal(negativeStartingStock(scan("e100", "portra400"), stocks, "gold200"), "portra400");
  assert.equal(negativeStartingStock(scan("unknown"), stocks, "gold200"), "gold200");
  assert.equal(negativeStartingStock(scan(), stocks, "e100"), "gold200");
  assert.equal(negativeStartingStock(null, [stock("e100", false)], null), null);
});

test("a negative offers its reading, its light, its print, its roll and its framing", () => {
  const photo = documentPanels(defaultEdit("gold200"), inspectorPanels, "develop");
  assert.equal(photo.panel, "develop");
  assert.equal(photo.inspectorPanels, inspectorPanels);
  // A photograph has no roll: one left on the Roll panel goes back to Film.
  assert.equal(documentPanels(defaultEdit("gold200"), inspectorPanels, "roll").panel, "film");
  const negative = documentPanels(negativeEdit("gold200"), inspectorPanels, "develop");
  assert.deepEqual(negative.inspectorPanels.map(({ id }) => id), ["film", "light", "print", "roll"]);
  assert.equal(negative.panel, "film");
  assert.equal(documentPanels(negativeEdit("gold200"), inspectorPanels, "crop").panel, "crop");
  assert.equal(documentPanels(negativeEdit("gold200"), inspectorPanels, "roll").panel, "roll");
  // Without a film it is a positive photograph, with every panel a photograph has and its roll.
  const plain = documentPanels(negativeEdit(null), inspectorPanels, "develop");
  assert.deepEqual(plain.inspectorPanels, [...inspectorPanels, ROLL_PANEL]);
  assert.equal(plain.panel, "develop");
  // The editor's own panels keep their order, and so their shortcuts.
  assert.ok(!inspectorPanels.some(({ id }) => id === "roll"));
});

test("a negative's reading is kept with its edit and checked when it is read back", () => {
  const border = [0.4, 0.2, 0.1];
  const kept = parseEdit(editText(negativeEdit("gold200", { border, lightFrame: "light" })),
    stocks.map(({ id }) => id));
  assert.deepEqual(kept.negative, { border, lightFrame: "light", roll: null });
  assert.equal(parseEdit(editText(defaultEdit("gold200")), ["gold200"]).negative, null);
  assert.throws(() => parseNegative({ border: [0.4, 0, 0.1] }), /negative reading/);
  assert.throws(() => parseNegative({ lightFrame: 3 }), /negative reading/);
  assert.deepEqual(parseEdit(editText(negativeEdit(null)), ["gold200"]).negative, newNegative());
});

test("a negative's roll balance is kept with its edit and checked when it is read back", () => {
  const roll = { colour: [0.92, 1.1], frames: 24 };
  const kept = parseEdit(editText(negativeEdit("gold200", { ...newNegative(), roll })),
    stocks.map(({ id }) => id));
  assert.deepEqual(kept.negative.roll, roll);
  for (const bad of [
    { colour: [0.9], frames: 3 },
    { colour: [0.9, 0], frames: 3 },
    { colour: [0.9, Infinity], frames: 3 },
    { colour: [0.9, 1], frames: 1 },
    { colour: [0.9, 1], frames: 2.5 },
    "roll",
  ])
    assert.throws(() => parseNegative({ roll: bad }), /negative reading/, JSON.stringify(bad));
  // An edit kept before rolls existed reads as balanced on its own frame.
  assert.equal(parseNegative({ border: null, lightFrame: null }).roll, null);
});

test("a roll is the strip's negatives from the shown frame's directory", () => {
  const doc = (id, editKey, negative = true) => ({
    id,
    editKey,
    source: { negative },
  });
  const shown = doc("a", "f1/roll-1/01.tif");
  const files = [
    doc("x", "f1/roll-2/01.tif"),
    shown,
    doc("b", "f1/roll-1/02.tif"),
    doc("c", "f1/roll-1/notes.jpg", false),
    doc("d", "f1/roll-1/sub/03.tif"),
    doc("e", "f2/roll-1/02.tif"),
    doc("f", "sha256:abc"),
  ];
  assert.equal(rollOf(shown), "f1/roll-1");
  assert.equal(rollOf(files.at(-1)), null);
  assert.deepEqual(rollDocuments(files, shown).map(({ id }) => id), ["a", "b"]);
  assert.deepEqual(rollDocuments(files, files.at(-1)), []);
  assert.deepEqual(rollDocuments(files, null), []);
});

test("pasting onto a negative keeps it a negative, read as a film it can be", () => {
  const base = { border: [0.5, 0.3, 0.2], lightFrame: null, roll: null };
  const roll = negativeEdit("portra400", base);
  // Another frame of the roll takes its film, base and light with the film.
  const frame = pastedEdit(negativeEdit("gold200"), copySettings(roll, DEFAULT_SECTIONS), stocks);
  assert.equal(frame.stock, "portra400");
  assert.deepEqual(frame.negative, base);
  // A slide's settings leave the negative on its own film and reading.
  const slide = pastedEdit(roll, copySettings(defaultEdit("e100"), DEFAULT_SECTIONS), stocks);
  assert.equal(slide.stock, "portra400");
  assert.deepEqual(slide.negative, base);
  // Normal carries between frames of a roll, as any film does.
  const normal = pastedEdit(roll, copySettings(negativeEdit(null, base), DEFAULT_SECTIONS), stocks);
  assert.equal(normal.stock, null);
  // A photograph never becomes a negative.
  const photo = pastedEdit(defaultEdit("gold200"), copySettings(roll, DEFAULT_SECTIONS), stocks);
  assert.equal(photo.negative, null);
});
