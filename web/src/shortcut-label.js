// Keyboard shortcuts as the platform writes them: the Mac's symbols (⇧⌘Z) on Apple systems, and
// Ctrl+Shift+Z where the desktop host runs on Linux or Windows. Labels are written the Mac way.
const MODIFIERS = [
  ["⌃", "Ctrl"],
  ["⌘", "Ctrl"],
  ["⌥", "Alt"],
  ["⇧", "Shift"],
];

export function isApplePlatform(nav = globalThis.navigator) {
  const platform = nav?.userAgentData?.platform || nav?.platform || nav?.userAgent || "";
  return /mac|iphone|ipad|ipod/i.test(platform);
}

export function shortcutLabel(keys, apple = isApplePlatform()) {
  if (apple) return keys;
  const held = MODIFIERS.filter(([symbol]) => keys.includes(symbol)).map(([, name]) => name);
  const key = MODIFIERS.reduce((rest, [symbol]) => rest.replaceAll(symbol, ""), keys);
  return [...new Set(held), key].join("+");
}
