import { createIcon } from "@react-spectrum/s2/Icon";
import symbols from "./material-symbols.json";

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
export function Icon({ name, size = 20, ...props }) {
  const Symbol = icons[name] || icons.film;
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
