import { createIcon } from "@react-spectrum/s2/Icon";
import symbols from "./material-symbols.json";
import { ICON_GLYPHS, glyphHref } from "./glyphs.jsx";

// Google Material Symbols Rounded, opsz 40. Bundle paths for offline editing.
const icons = Object.fromEntries(
  Object.entries(symbols).map(([name, symbol]) => [
    name,
    createIcon((props) => (
      <svg
        {...props}
        viewBox={symbol.viewBox}
        fill="currentColor"
        data-symbol={symbol.name}
      >
        {symbol.paths.map((d, index) => (
          <path key={index} d={d} />
        ))}
      </svg>
    )),
  ]),
);
// Where Fotufilm's own glyph set draws an icon, it replaces the generic symbol.
const glyphs = Object.fromEntries(
  Object.entries(ICON_GLYPHS).map(([name, glyph]) => [
    name,
    createIcon((props) => (
      <svg {...props} viewBox="0 0 24 24" data-glyph={glyph}>
        <use href={glyphHref(glyph)} />
      </svg>
    )),
  ]),
);
export function Icon({ name, size = 20, ...props }) {
  const Symbol = glyphs[name] || icons[name] || glyphs.film;
  return (
    <Symbol
      {...props}
      UNSAFE_style={
        size
          ? {
              width: size,
              height: size,
              flexShrink: 0,
            }
          : undefined
      }
    />
  );
}
