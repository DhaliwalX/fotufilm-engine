import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit, parseEdit } from "../../src/editor-state.js";
import { DEFAULT_SECTIONS, copySettings, pastedEdit } from "../../src/edit-settings.js";
import { editText } from "../../src/saved-edits.js";
import { inspectorPanels } from "../../src/editor-catalogue.js";
import {
  documentPanels,
  negativeStartingStock,
  newNegative,
  parseNegative,
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

test("a negative offers its reading, its light, its print and its framing", () => {
  const photo = documentPanels(defaultEdit("gold200"), inspectorPanels, "develop");
  assert.equal(photo.panel, "develop");
  assert.equal(photo.inspectorPanels, inspectorPanels);
  const negative = documentPanels(negativeEdit("gold200"), inspectorPanels, "develop");
  assert.deepEqual(negative.inspectorPanels.map(({ id }) => id), ["film", "light", "print"]);
  assert.equal(negative.panel, "film");
  assert.equal(documentPanels(negativeEdit("gold200"), inspectorPanels, "crop").panel, "crop");
  // Without a film it is a positive photograph, with every panel a photograph has.
  const plain = documentPanels(negativeEdit(null), inspectorPanels, "develop");
  assert.equal(plain.inspectorPanels, inspectorPanels);
  assert.equal(plain.panel, "develop");
});

test("a negative's reading is kept with its edit and checked when it is read back", () => {
  const border = [0.4, 0.2, 0.1];
  const kept = parseEdit(editText(negativeEdit("gold200", { border, lightFrame: "light" })),
    stocks.map(({ id }) => id));
  assert.deepEqual(kept.negative, { border, lightFrame: "light" });
  assert.equal(parseEdit(editText(defaultEdit("gold200")), ["gold200"]).negative, null);
  assert.throws(() => parseNegative({ border: [0.4, 0, 0.1] }), /negative reading/);
  assert.throws(() => parseNegative({ lightFrame: 3 }), /negative reading/);
  assert.deepEqual(parseEdit(editText(negativeEdit(null)), ["gold200"]).negative, newNegative());
});

test("pasting onto a negative keeps it a negative, read as a film it can be", () => {
  const base = { border: [0.5, 0.3, 0.2], lightFrame: null };
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
