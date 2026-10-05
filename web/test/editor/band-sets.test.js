import test from "node:test";
import assert from "node:assert/strict";

test("band sets save by name, replace a namesake, sort, read back and delete", async () => {
  const stored = new Map();
  globalThis.localStorage = {
    getItem: (key) => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value),
    removeItem: (key) => stored.delete(key),
  };
  try {
    const { saveBandSet, deleteBandSet, editBands, sameBands } = await import(
      "../../src/band-sets.js"
    );
    const paper = { red: 700, green: 545, blue: 470 };
    saveBandSet("RM120 LEDs", { red: 625, green: 522, blue: 455 });
    saveBandSet("Minilab", { red: 630, green: 545, blue: 465 });
    saveBandSet("RM120 LEDs", { red: 626, green: 522, blue: 455 });
    const sets = JSON.parse(stored.get("fotufilm.receiverBandSets"));
    assert.deepEqual(sets.map((s) => s.name), ["Minilab", "RM120 LEDs"]);
    assert.equal(sets[1].red, 626);
    deleteBandSet("Minilab");
    assert.deepEqual(
      JSON.parse(stored.get("fotufilm.receiverBandSets")).map((s) => s.name),
      ["RM120 LEDs"],
    );
    assert.deepEqual(editBands({ screenGreenBand: 522 }, paper), { red: 700, green: 522, blue: 470 });
    assert.ok(sameBands(editBands({}, paper), paper));
    assert.ok(!sameBands(null, paper));
  } finally {
    delete globalThis.localStorage;
  }
});
