// The Edit History, named as the native Mac app names it: each step is called after what it changed, so Undo and
// Redo can say what they will undo, and the timeline can be read and jumped through.

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const changed = (before, after, keys) =>
  keys.some((key) => !same(before?.[key], after?.[key]));
const paramsChanged = (before, after, keys) =>
  keys.some((key) => !same(before?.params?.[key], after?.params?.[key]));
const profileChanged = (before, after, test) => {
  const fields = new Set([
    ...Object.keys(before?.profile || {}),
    ...Object.keys(after?.profile || {}),
  ]);
  return [...fields].some(
    (field) => test(field) && !same(before?.profile?.[field], after?.profile?.[field]),
  );
};
const GRADE = /^grade(Shadows|Midtones|Highlights)(Warmth|Tint|Level)$/;
const PRINTER = /^printer/;
const FILM_GRAIN = /^(grainMottle|grainModel|film(GrainSize|ColourGrain|RedLayer|GreenLayer|BlueLayer|ScanSoftness))$/;

// The name of the step from `before` to `after`, checked in the Mac app's order. `filmName`
// turns a film id into what the film list calls it.
export function historyTitle(before, after, filmName = () => "Film") {
  const kind = cachedKind(before, after);
  if (typeof kind === "string") return kind;
  return kind.film ? filmName(kind.film) || "Film" : "Normal";
}

// Edits are never changed in place, so a step's kind is worked out once per pair of states: the
// menus ask for the whole timeline on every change.
const kinds = new WeakMap();
function cachedKind(before, after) {
  if (!after || typeof after !== "object") return stepKind(before, after);
  const hit = kinds.get(after);
  if (hit && hit.before === before) return hit.kind;
  const kind = stepKind(before, after);
  kinds.set(after, { before, kind });
  return kind;
}

// What a step changed: a title, or `{film}` for a change of film, which is named at the time.
function stepKind(before, after) {
  if (!same(before?.stock, after?.stock)) return { film: after?.stock ?? null };
  if (!same(before?.format, after?.format)) return "Film Format";
  if (
    changed(before, after, [
      "crop",
      "cropShape",
      "ratio",
      "rotation",
      "flip",
      "straighten",
      "perspectiveV",
      "perspectiveH",
    ])
  )
    return "Crop & Rotate";
  if (changed(before, after, ["filters", "filterMetering"])) return "Lens Filters";
  if (changed(before, after, ["lens"])) return "Lens Correction";
  if (changed(before, after, ["sourceInterpretation"])) return "Source Interpretation";
  if (
    changed(before, after, ["sceneLight"]) ||
    paramsChanged(before, after, ["sceneLightKelvin"])
  )
    return "Source Illuminant";
  if (
    changed(before, after, ["localTone"]) ||
    paramsChanged(before, after, ["ev", "highlights", "shadows", "cameraPreflash"])
  )
    return "Light";
  if (paramsChanged(before, after, ["temperature", "tint"])) return "Undertone";
  if (paramsChanged(before, after, ["saturation", "vibrance"])) return "Color";
  if (
    paramsChanged(before, after, ["grain"]) ||
    profileChanged(before, after, (field) => FILM_GRAIN.test(field))
  )
    return "Grain";
  if (changed(before, after, ["seed"])) return "Grain Pattern";
  if (
    changed(before, after, ["halationModel"]) ||
    profileChanged(before, after, (field) => field.startsWith("halation") || field === "estimatedHalation")
  )
    return "Halation";
  if (profileChanged(before, after, (field) => field.startsWith("coupler")))
    return "Couplers";
  if (profileChanged(before, after, (field) => field.startsWith("chromaticFringe")))
    return "Chromatic Fringe";
  if (profileChanged(before, after, (field) => ["push", "bleach", "expired", "shutter"].includes(field)))
    return "Lab";
  if (
    changed(before, after, ["gradeSpace"]) ||
    Object.keys({ ...before?.params, ...after?.params }).some(
      (key) => GRADE.test(key) && paramsChanged(before, after, [key]),
    )
  )
    return "Grade";
  if (changed(before, after, ["medium"])) return "Output Medium";
  if (profileChanged(before, after, (field) => field === "printLight"))
    return "Viewing Illuminant";
  if (changed(before, after, ["digitalReference"])) return "Screen Conversion";
  if (profileChanged(before, after, (field) => field === "screenGrade")) return "Paper Grade";
  if (profileChanged(before, after, (field) => field === "screenExposure"))
    return "Screen Exposure";
  if (profileChanged(before, after, (field) => field === "enlarger" || PRINTER.test(field)))
    return "Enlarger";
  if (profileChanged(before, after, (field) => field === "printCorrection"))
    return "Channel Contrast Match";
  if (profileChanged(before, after, (field) => field === "negativeViewing"))
    return "Negative Viewing";
  if (changed(before, after, ["printFrame"])) return "Print Frame";
  if (changed(before, after, ["selective"])) return "Selective";
  if (changed(before, after, ["video"])) return "Video";
  return "Edit";
}

// The whole timeline, oldest first — what undo walks back through, the state standing now and
// what redo walks forward into — named step by step, and the step standing now.
export function editHistory(history, filmName) {
  const states = [...history.past, history.present, ...history.future];
  return {
    titles: states.map((state, index) =>
      index === 0 ? "Opened" : historyTitle(states[index - 1], state, filmName),
    ),
    index: history.past.length,
  };
}

// "Undo Lens Correction", or plain "Undo" when there is nothing to undo; likewise Redo.
export function undoTitle(history, filmName) {
  return history.past.length
    ? `Undo ${historyTitle(history.past.at(-1), history.present, filmName)}`
    : "Undo";
}
export function redoTitle(history, filmName) {
  return history.future.length
    ? `Redo ${historyTitle(history.present, history.future[0], filmName)}`
    : "Redo";
}

// A film id to the name the film list shows.
export const filmNamer = (stocks) => (id) =>
  stocks?.find((stock) => stock.id === id)?.name;
