// The names of Fotufilm's own editor glyphs (shared/Glyphs, CC BY-SA 4.0) and where the one
// sprite the build publishes at glyphs/glyphs.svg holds them.
import { EDITOR_CONTROLS } from "./generated/controls.js";

const SPRITE = `${import.meta.env?.BASE_URL ?? "/"}glyphs/glyphs.svg`;

/** Where a glyph is in the sprite. */
export const glyphHref = (name) => `${SPRITE}#${name}`;

/**
 * The editor's icon names the glyph set draws, as the Mac and iPad apps pick them
 * (shared/FotufilmApp/EditorGlyphs.swift): the inspector's stages, the selection and the crop.
 */
export const ICON_GLYPHS = {
  film: "fotu.deck.film",
  expose: "fotu.deck.light",
  develop: "fotu.tab.lab",
  print: "fotu.deck.print",
  adjustments: "fotu.deck.controls",
  selective: "fotu.tab.local",
  crop: "fotu.tab.geometry",
  lens: "fotu.deck.lens",
};

// The editor's own names for sliders the catalogue calls otherwise. Temperature is the light
// being corrected for, on a mired scale: its left end is the warmer picture.
const SLIDER_FIELDS = { ev: "exposure", temperature: "warmth" };
const REVERSED = new Set(["temperature"]);

// The set draws a low and a high glyph for every catalogue slider but the grade's (the deck
// draws those), Straighten and the halo's construction controls.
const WITHOUT_ENDS =
  /^grade(Shadows|Midtones|Highlights)|^(straighten|halationHaze|antiHalation|baseThickness|pressurePlate)$/;
const ENDED = new Set(
  EDITOR_CONTROLS.filter(
    (control) => control.kind === "slider" && !WITHOUT_ENDS.test(control.field),
  ).map((control) => control.field),
);

/** The glyphs at a slider's low and high ends, or null where the set draws none. */
export function sliderEnds(key) {
  const field = SLIDER_FIELDS[key] ?? key;
  if (!ENDED.has(field)) return null;
  const low = `fotu.slider.${field}.low`, high = `fotu.slider.${field}.high`;
  return REVERSED.has(key) ? { low: high, high: low } : { low, high };
}
