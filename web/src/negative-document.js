import { NEGATIVE } from "./engine-constants.js";

// A scanned negative opened as a document. The scan is the film after development, so its edit
// is any photograph's with `negative` set: the film is the one the scan is read as, the print is
// the editor's own, and the stages before the negative existed (exposure, development, grain)
// have nothing to act on. The host reads the framed scan as the film's densities and prints them
// (Sources/FotufilmHost/HostService+NegativeScan.swift). With no film (Normal) the scan reads as a
// plain positive (PlainNegativeScan), edited like any photograph without film.

// How the scan is read (WebNativeEdit.Negative): the clear film it is measured against (linear
// Rec. 2020 scan RGB, null to estimate it from the thinnest film), the light frame that evens its
// light, what its roll measured (rollBalance, null for none), how far the reading undoes the
// crosstalk between the scan's channels and the film's dyes (0 to 1, NegativeScanCrosstalk), and
// the light the scan was made under: a white LED panel ("white"), a phone or tablet screen, a
// halogen lamp, or "rgb" for exposures under red, green and blue LEDs merged into one scan. The
// current reading adds which reading the edit was made with (`reading`), what took the scan
// (`camera`: "generic", "scanner", or absent for the camera its file names), what the frame is
// balanced on (`balance`, absent for its own tones) and something neutral picked on it
// (`neutral`, scan RGB like `border`).
export const SCAN_LIGHTS = ["white", "screen", "halogen", "rgb"];
export const BALANCES = ["frame", "roll", "none"];
// A new negative is read with the current reading (`reading`, engine-constants.js NEGATIVE):
// through the scan's light and camera, the dyes separated all the way. An edit saved before
// keeps the first reading until it is updated.
export const newNegative = (scanLight = "white", reading = NEGATIVE.currentReading) => ({
  border: null,
  lightFrame: null,
  roll: null,
  crosstalk: reading >= 2 ? 1 : 0,
  scanLight,
  ...(reading >= 2 ? { reading } : {}),
});

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

// How many frames' tonal steps a roll's contrast takes (RollBalance.contrastFrames).
const CONTRAST_FRAMES = 6;

// What a roll's frames share (ApproximateNegativeScan.RollBalance(measures:)), from what each
// frame measures: its densest end (`denseEnd`) and the rises across its tonal steps (`slopes`).
// Over the frames whose densest ends can be read, `colour` is the median of each end's red and
// blue density per unit of its green and `level` the median green; `slopes` is the median rise
// over the frames that have one, left out with fewer than six. Frames shot on one roll under one
// light share these; a frame filled by one colour moves a median little. Null when fewer than two
// frames' densest ends can be read.
export function rollBalance(measures) {
  const frames = measures.map((measure) => measure?.denseEnd).filter(readable);
  if (frames.length < 2) return null;
  const median = (values) => {
    const sorted = values.sort((a, b) => a - b),
      middle = sorted.length >> 1;
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  };
  const stepped = measures
    .map((measure) => measure?.slopes)
    .filter(
      (slopes) =>
        Array.isArray(slopes) &&
        slopes.length === 2 &&
        slopes.every((v) => Number.isFinite(v) && v > 0),
    );
  return {
    colour: [0, 2].map((c) => median(frames.map((dense) => dense[c] / dense[1]))),
    frames: frames.length,
    level: median(frames.map((dense) => dense[1])),
    ...(stepped.length >= CONTRAST_FRAMES
      ? { slopes: [0, 1].map((c) => median(stepped.map((slopes) => slopes[c]))) }
      : {}),
  };
}

// A frame's densest end read on its roll's colour: its own green, which times its print, with
// red and blue in the roll's proportion to it. Mirrors ApproximateNegativeScan.denseEnd(_:roll:).
export function rolledDenseEnd(dense, roll) {
  if (!roll || !dense || !dense.every(Number.isFinite) || !(dense[1] > READABLE)) return dense;
  return [roll.colour[0] * dense[1], dense[1], roll.colour[1] * dense[1]];
}

// Whether an edit reads the film through the scan's light and camera and balances as it says,
// or with the first reading, which an edit saved with it keeps (WebNativeEdit.Negative.readsModel).
export const readsModel = (negative) => (negative?.reading ?? 1) >= 2;

// What a request says of a negative's reading (WebProfileRequest.Negative), from its edit, what
// its framing measures (`border`, its own densest end `dense`) and what the scan's file says of
// its camera (`source`). The first reading takes the frame's densest end on its roll's colour;
// the current one takes the frame's own and the roll beside it.
export function readingRequest(negative, { border, dense }, source = null) {
  if (!readsModel(negative))
    return {
      border,
      denseEnd: rolledDenseEnd(dense, negative.roll),
      crosstalk: negative.crosstalk ?? 0,
      scanLight: negative.scanLight ?? "white",
    };
  const kept = {};
  for (const key of ["reading", "crosstalk", "scanLight", "camera", "balance", "neutral", "roll"])
    if (negative[key] != null) kept[key] = negative[key];
  return { border, denseEnd: dense, ...kept, ...(source ? { source } : {}) };
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
  const {
    border = null,
    lightFrame = null,
    roll = null,
    crosstalk = 0,
    scanLight = "white",
    reading = null,
    camera = null,
    balance = null,
    neutral = null,
  } = value;
  const positives = (values, count) =>
    Array.isArray(values) &&
    values.length === count &&
    values.every((v) => Number.isFinite(v) && v > 0);
  if (
    (border !== null && !positives(border, 3)) ||
    (lightFrame !== null && typeof lightFrame !== "string") ||
    !(Number.isFinite(crosstalk) && crosstalk >= 0 && crosstalk <= 1) ||
    !SCAN_LIGHTS.includes(scanLight) ||
    (roll !== null &&
      !(
        positives(roll?.colour, 2) &&
        Number.isInteger(roll.frames) &&
        roll.frames >= 2 &&
        (roll.level == null || (Number.isFinite(roll.level) && roll.level > 0)) &&
        (roll.slopes == null || positives(roll.slopes, 2))
      )) ||
    (reading !== null && !(Number.isInteger(reading) && reading >= 1)) ||
    (camera !== null && (typeof camera !== "string" || !camera)) ||
    (balance !== null && !BALANCES.includes(balance)) ||
    (neutral !== null && !positives(neutral, 3))
  )
    throw new Error("Invalid negative reading.");
  return {
    border,
    lightFrame,
    roll: roll && {
      colour: [...roll.colour],
      frames: roll.frames,
      ...(roll.level != null ? { level: roll.level } : {}),
      ...(roll.slopes != null ? { slopes: [...roll.slopes] } : {}),
    },
    crosstalk,
    scanLight,
    ...(reading !== null ? { reading } : {}),
    ...(camera !== null ? { camera } : {}),
    ...(balance !== null ? { balance } : {}),
    ...(neutral !== null ? { neutral: [...neutral] } : {}),
  };
}
