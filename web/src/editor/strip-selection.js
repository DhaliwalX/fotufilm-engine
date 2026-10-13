import { nextSelection } from "../photo-library/library-model.js";

// The photos chosen in the strip below the canvas, which Paste Settings and presets apply to.
// A click shows a photo and chooses it alone; Shift-click and Command/Control-click choose more
// without changing the one shown, as the library grid's clicks do. The shown photo is always
// among them.

export const stripStart = (activeId = null) => ({
  selected: new Set(activeId ? [activeId] : []),
  anchor: activeId,
});

/** The selection after pressing the photo `id`, with `range` (Shift) or `toggle` (Command). */
export function pressedStrip(
  files,
  activeId,
  selection,
  id,
  { range = false, toggle = false } = {},
) {
  // A plain click leaves the others; the photo it shows is chosen once it is shown, which for one
  // not opened yet waits for it to decode.
  if (!range && !toggle) return stripStart(null);
  const keys = files.map((file) => ({ key: file.id }));
  const current = {
    selected: new Set([...chosenIds(files, activeId, selection)]),
    anchor: selection.anchor ?? activeId,
  };
  const next = nextSelection(keys, current, id, { range, toggle });
  // The photo shown stays chosen: Command-click on it leaves the selection as it was.
  if (activeId && !next.selected.has(activeId)) return current;
  return next;
}

/** Every open photo. */
export const allStrip = (files, activeId) => ({
  selected: new Set(files.map((file) => file.id)),
  anchor: activeId,
});

/** The ids chosen among `files`: the shown photo and the others still open. */
export function chosenIds(files, activeId, selection) {
  const open = new Set(files.map((file) => file.id));
  const ids = new Set([...selection.selected].filter((id) => open.has(id)));
  if (activeId && open.has(activeId)) ids.add(activeId);
  return ids;
}

/** The chosen photos, in the strip's order. */
export function chosenFiles(files, activeId, selection) {
  const ids = chosenIds(files, activeId, selection);
  return files.filter((file) => ids.has(file.id));
}
