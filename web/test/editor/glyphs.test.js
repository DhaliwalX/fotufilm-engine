import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { EDITOR_CONTROLS } from "../../src/generated/controls.js";
import { ICON_GLYPHS, sliderEnds } from "../../src/glyph-names.js";

const sprite = readFileSync(new URL("../../public/glyphs/glyphs.svg", import.meta.url), "utf8");
const drawn = new Set([...sprite.matchAll(/<symbol id="([^"]+)"/g)].map((match) => match[1]));

test("every icon the editor takes from the glyph set is in the sprite", () => {
  for (const glyph of Object.values(ICON_GLYPHS)) assert.ok(drawn.has(glyph), glyph);
});

test("every slider given ends has both glyphs in the sprite", () => {
  const sliders = EDITOR_CONTROLS.filter((control) => control.kind === "slider");
  const ended = sliders.map((control) => sliderEnds(control.field)).filter(Boolean);
  assert.ok(ended.length >= 40);
  for (const { low, high } of ended) {
    assert.ok(drawn.has(low), low);
    assert.ok(drawn.has(high), high);
  }
  // The editor's own names reach the catalogue's glyphs; Temperature's left end is warmer.
  assert.deepEqual(sliderEnds("ev"), sliderEnds("exposure"));
  assert.equal(sliderEnds("temperature").low, "fotu.slider.warmth.high");
  assert.equal(sliderEnds("gradeShadowsWarmth"), null);
});
