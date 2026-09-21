import icons from './material-symbols.json'

// Material Symbols Outlined, bundled as SVG paths so controls also work offline.
export function Icon({ name, size = 18, ...props }) {
  const symbol = icons[name] || icons.film
  return (
    <svg
      width={size}
      height={size}
      viewBox={symbol.viewBox}
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
      data-symbol={symbol.name}
      {...props}
    >
      {symbol.paths.map((path, index) => <path key={index} d={path} />)}
    </svg>
  )
}

// Match the editor icons in Astryx selectors, inputs and their status messages.
export const controlIcons = Object.fromEntries(
  [
    'close',
    'chevronDown',
    'chevronLeft',
    'chevronRight',
    'check',
    'success',
    'error',
    'warning',
    'info',
    'search',
  ].map((name) => [name, <Icon key={name} name={name} size="1em" />]),
)
