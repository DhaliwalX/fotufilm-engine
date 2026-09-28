// Fotufilm's own editor glyphs, drawn from the sprite (glyph-names.js). Uncoloured parts follow
// currentColor; coloured ones read the --fotu-system* colours, which base.css sets for the page's
// appearance.
import { glyphHref } from "./glyph-names.js";

export { ICON_GLYPHS, glyphHref, sliderEnds } from "./glyph-names.js";

/** A glyph by its name in the set (`fotu.deck.film`, `fotu.slider.exposure.low`, …). */
export function Glyph({ name, size = 20, className, style, ...props }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      aria-hidden="true"
      focusable="false"
      className={className}
      style={{ flexShrink: 0, ...style }}
      data-glyph={name}
      {...props}
    >
      <use href={glyphHref(name)} />
    </svg>
  );
}

