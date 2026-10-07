// A scanned negative opened as a document. The scan is the film after development, so its edit
// is any photograph's with `negative` set: the film is the one the scan is read as, the print is
// the editor's own, and the stages before the negative existed (exposure, development, grain)
// have nothing to act on. The host reads the framed scan as the film's densities and prints them
// (Sources/FotufilmHost/HostService+NegativeScan.swift). With no film (Normal) the scan reads as a
// plain positive (PlainNegativeScan), edited like any photograph without film.

// How the scan is read: the clear film it is measured against (linear Rec. 2020 scan RGB, null
// to estimate it from the thinnest film) and the light source it was scanned on.
export const newNegative = () => ({ border: null, lightFrame: null });

// The inspector panels a negative read as a film offers: the reading, the light controls (which
// act on the print, NegativeScanPrint.printing), the print, and its framing.
export const NEGATIVE_PANELS = ["film", "light", "print", "crop"];

// Whether an edit is a scanned negative read as a film, printed from its densities.
export const printsNegative = (edit) => !!edit?.negative && edit.stock !== null;

// Whether an edit offers a panel: a negative read as a film offers its reading, its light, its
// print and its framing; one read without a film offers what any photograph does.
export const offersPanel = (edit, id) => !printsNegative(edit) || NEGATIVE_PANELS.includes(id);

// The panels an edit offers, from the editor's, and the one shown: a negative's Film panel
// stands in for one it does not offer.
export function documentPanels(edit, panels, panel) {
  if (!printsNegative(edit)) return { inspectorPanels: panels, panel };
  return {
    inspectorPanels: panels.filter(({ id }) => NEGATIVE_PANELS.includes(id)),
    panel: NEGATIVE_PANELS.includes(panel) ? panel : "film",
  };
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
  const { border = null, lightFrame = null } = value;
  if (
    (border !== null &&
      !(
        Array.isArray(border) &&
        border.length === 3 &&
        border.every((v) => Number.isFinite(v) && v > 0)
      )) ||
    (lightFrame !== null && typeof lightFrame !== "string")
  )
    throw new Error("Invalid negative reading.");
  return { border, lightFrame };
}
