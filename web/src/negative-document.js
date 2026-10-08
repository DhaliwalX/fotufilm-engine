// A scanned negative opened as a document. The scan is the film after development, so its edit
// is any photograph's with `negative` set: the film is the one the scan is read as, the print is
// the editor's own, and the stages before the negative existed (exposure, development, grain)
// have nothing to act on. The host reads the framed scan as the film's densities and prints them
// (Sources/FotufilmHost/HostService+NegativeScan.swift). With no film (Normal) the scan reads as a
// plain positive (PlainNegativeScan), edited like any photograph without film.

// How the scan is read: the clear film it is measured against (linear Rec. 2020 scan RGB, null
// to estimate it from the thinnest film), the light source it was scanned on, and the colour of
// its roll it is balanced on (rollBalance, null for its own).
export const newNegative = () => ({ border: null, lightFrame: null, roll: null });

// The inspector panels a negative read as a film offers: the reading, the light controls (which
// act on the print, NegativeScanPrint.printing), the print, its roll and its framing.
export const NEGATIVE_PANELS = ["film", "light", "print", "roll", "crop"];

// The Roll panel: what the frames of a roll share. Only a scanned negative offers it, read as a
// film or without one; it follows the editor's own panels, so their shortcuts stay as they are.
export const ROLL_PANEL = { id: "roll", icon: "negative", title: "Roll" };

// Whether an edit is a scanned negative read as a film, printed from its densities.
export const printsNegative = (edit) => !!edit?.negative && edit.stock !== null;

// Whether an edit offers a panel: a negative read as a film offers its reading, its light, its
// print and its framing; one read without a film offers what any photograph does.
export const offersPanel = (edit, id) => !printsNegative(edit) || NEGATIVE_PANELS.includes(id);

// The panels an edit offers, from the editor's, and the one shown: a negative's Film panel
// stands in for one it does not offer.
export function documentPanels(edit, panels, panel) {
  if (!edit?.negative)
    return { inspectorPanels: panels, panel: panel === ROLL_PANEL.id ? "film" : panel };
  if (!printsNegative(edit)) return { inspectorPanels: [...panels, ROLL_PANEL], panel };
  return {
    inspectorPanels: [...panels, ROLL_PANEL].filter(({ id }) => NEGATIVE_PANELS.includes(id)),
    panel: NEGATIVE_PANELS.includes(panel) ? panel : "film",
  };
}

// The roll a document belongs to: the directory its kept edit's key names (a library folder's
// photo, or a file the host keeps by its path). Null for one known by its contents alone.
export function rollOf(doc) {
  const key = doc?.editKey;
  const slash = typeof key === "string" ? key.lastIndexOf("/") : -1;
  return slash < 0 ? null : key.slice(0, slash);
}

// The strip's scanned negatives on `active`'s roll, `active` among them, in the strip's order.
export function rollDocuments(files, active) {
  const roll = rollOf(active);
  if (roll === null) return [];
  return files.filter(
    (doc) =>
      rollOf(doc) === roll &&
      (doc.id === active.id || !!doc.image?.negative || !!doc.source?.negative),
  );
}

// Densest ends too thin to tell a colour from, as ApproximateNegativeScan.balance holds them.
const READABLE = 0.05;
const readable = (dense) =>
  Array.isArray(dense) && dense.length === 3 && dense.every((v) => Number.isFinite(v) && v > READABLE);

// A roll's colour (ApproximateNegativeScan.RollBalance): over the frames whose densest ends can be
// read, the median of each end's red and blue density per unit of its green. Frames shot on one
// roll under one light share it; a frame filled by one colour moves a median little. Null when
// fewer than two frames can be read.
export function rollBalance(denseEnds) {
  const frames = denseEnds.filter(readable);
  if (frames.length < 2) return null;
  const median = (values) => {
    const sorted = values.sort((a, b) => a - b),
      middle = sorted.length >> 1;
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  };
  return {
    colour: [0, 2].map((c) => median(frames.map((dense) => dense[c] / dense[1]))),
    frames: frames.length,
  };
}

// A frame's densest end read on its roll's colour: its own green, which times its print, with
// red and blue in the roll's proportion to it. Mirrors ApproximateNegativeScan.denseEnd(_:roll:).
export function rolledDenseEnd(dense, roll) {
  if (!roll || !dense || !dense.every(Number.isFinite) || !(dense[1] > READABLE)) return dense;
  return [roll.colour[0] * dense[1], dense[1], roll.colour[1] * dense[1]];
}

// "Gold 200", "Vision3 500T or CineStill 800T", "Tri-X 400 and 7 similar films".
export function suggestionName({ films }) {
  return films.length > 2
    ? `${films[0].name} and ${films.length - 1} similar films`
    : films.map((film) => film.name).join(" or ");
}

// Whether a film has a negative to read a scan as: slides and papers do not.
export const readsNegative = (stock) => stock?.readsNegative === true;

// The film a new negative opens on: the first film its base looks like, else the film already
// chosen, else the first film that reads negatives.
export function negativeStartingStock(image, stocks, current) {
  const readable = stocks.filter(readsNegative);
  const ids = new Set(readable.map(({ id }) => id));
  const suggested = (image?.negative?.suggestions ?? [])
    .flatMap(({ films }) => films.map(({ id }) => id))
    .find((id) => ids.has(id));
  return suggested ?? (ids.has(current) ? current : (readable[0]?.id ?? null));
}

// A saved edit's reading, or an error for one that cannot be read.
export function parseNegative(value) {
  if (value == null) return null;
  const { border = null, lightFrame = null, roll = null } = value;
  if (
    (border !== null &&
      !(
        Array.isArray(border) &&
        border.length === 3 &&
        border.every((v) => Number.isFinite(v) && v > 0)
      )) ||
    (lightFrame !== null && typeof lightFrame !== "string") ||
    (roll !== null &&
      !(
        Array.isArray(roll?.colour) &&
        roll.colour.length === 2 &&
        roll.colour.every((v) => Number.isFinite(v) && v > 0) &&
        Number.isInteger(roll.frames) &&
        roll.frames >= 2
      ))
  )
    throw new Error("Invalid negative reading.");
  return {
    border,
    lightFrame,
    roll: roll && { colour: [...roll.colour], frames: roll.frames },
  };
}
