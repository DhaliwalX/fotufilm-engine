// A scanned negative's conversion as the engine keeps it (Sources/FotufilmEditModel/
// NegativeScanRecipe.swift): the page edits the same fields and the host prints them. The host
// supplies the starting recipe, so defaults live in one place; the helpers below are the Swift
// ones, restated for the controls.

export const EXPOSURE = { min: -3, max: 3, step: 0.05 };
export const COLOUR = { min: -1, max: 1, step: 0.01 };
export const TONE = { min: -1, max: 1, step: 0.01 };
export const STRAIGHTEN = { min: -15, max: 15, step: 0.1 };
export const GRADES = { min: 0, max: 5, step: 0.1 };
export const FULL_AREA = Object.freeze({ x: 0, y: 0, width: 1, height: 1 });
const ADJUSTMENTS = ["exposure", "warmth", "tint", "contrast", "highlights", "shadows"];

const turns = (value) => (((value ?? 0) % 4) + 4) % 4;
const clamp = (value, min, max) => Math.min(Math.max(value, min), max);

export const isFullArea = (area) =>
  !area ||
  (area.x === 0 && area.y === 0 && area.width === 1 && area.height === 1);

// NegativeScanRecipe.Area.clamped: inside the frame and at least `minimum` a side.
export function clampArea(area, minimum = 0.05) {
  const width = clamp(area.width, minimum, 1),
    height = clamp(area.height, minimum, 1);
  return {
    x: clamp(area.x, 0, 1 - width),
    y: clamp(area.y, 0, 1 - height),
    width,
    height,
  };
}

// A unit point of the scan's own frame in the oriented picture, and back.
export function orient(recipe, [x, y]) {
  let p = [recipe.mirrored ? 1 - x : x, y];
  for (let i = 0; i < turns(recipe.quarterTurns); i++) p = [1 - p[1], p[0]];
  return p;
}

export function unorient(recipe, point) {
  let p = point;
  for (let i = 0; i < turns(recipe.quarterTurns); i++) p = [p[1], 1 - p[0]];
  return [recipe.mirrored ? 1 - p[0] : p[0], p[1]];
}

function mapArea(area, map) {
  const a = map([area.x, area.y]),
    b = map([area.x + area.width, area.y + area.height]);
  return {
    x: Math.min(a[0], b[0]),
    y: Math.min(a[1], b[1]),
    width: Math.abs(b[0] - a[0]),
    height: Math.abs(b[1] - a[1]),
  };
}

export const orientArea = (recipe, area) => mapArea(area, (p) => orient(recipe, p));
export const unorientArea = (recipe, area) => mapArea(area, (p) => unorient(recipe, p));

// Turns the picture a quarter counter-clockwise, keeping the same part of the scan in the crop.
export function rotateLeft(recipe) {
  const kept = unorientArea(recipe, recipe.crop ?? FULL_AREA);
  const next = { ...recipe, quarterTurns: turns((recipe.quarterTurns ?? 0) + 3) };
  return { ...next, crop: orientArea(next, kept) };
}

// NegativeScanRecipe.toggleMirror: flips as shown, keeping the crop on the same part of the
// scan; on a turned picture the scan's own flip reads upside down, so a half turn goes with it.
export function toggleMirror(recipe) {
  const kept = unorientArea(recipe, recipe.crop ?? FULL_AREA);
  let quarterTurns = turns(recipe.quarterTurns);
  if (quarterTurns % 2) quarterTurns = turns(quarterTurns + 2);
  const next = { ...recipe, mirrored: !recipe.mirrored, quarterTurns };
  return { ...next, crop: orientArea(next, kept), straighten: -(recipe.straighten ?? 0) };
}

export const resetFraming = (recipe) => ({
  ...recipe,
  crop: { ...FULL_AREA },
  quarterTurns: 0,
  mirrored: false,
  straighten: 0,
});

export const isFramed = (recipe) =>
  !isFullArea(recipe.crop) ||
  turns(recipe.quarterTurns) !== 0 ||
  recipe.mirrored ||
  recipe.straighten !== 0;

// Width over height of the oriented scan.
export function orientedAspect(recipe, width, height) {
  return turns(recipe.quarterTurns) % 2 ? height / width : width / height;
}

// The crop aspects the apps offer (AspectOption), oriented to the picture: a portrait picture
// takes portrait crops.
export const ASPECTS = ["Free", "Original", "1:1", "4:5", "3:2", "16:9"];

export function aspectRatio(aspect, frameAspect) {
  if (aspect === "Free") return null;
  if (aspect === "Original") return frameAspect;
  const [a, b] = aspect.split(":").map(Number);
  return frameAspect < 1 ? Math.min(a, b) / Math.max(a, b) : Math.max(a, b) / Math.min(a, b);
}

// A crop of `ratio` (width over height) centred in a frame of `frameAspect`.
export function centredCrop(ratio, frameAspect) {
  const width = ratio < frameAspect ? ratio / frameAspect : 1;
  const height = ratio < frameAspect ? 1 : frameAspect / ratio;
  return { x: (1 - width) / 2, y: (1 - height) / 2, width, height };
}

// A multigrade paper's grade and the contrast it prints at: a third of the scale a grade,
// grade 2 at none.
export const contrastForGrade = (grade) =>
  (clamp(grade, GRADES.min, GRADES.max) - 2) / 3;
export const gradeForContrast = (contrast) =>
  clamp(contrast * 3 + 2, GRADES.min, GRADES.max);

export const isAdjusted = (recipe) =>
  ADJUSTMENTS.some((key) => (recipe[key] ?? 0) !== 0);

export const resetAdjustments = (recipe) => ({
  ...recipe,
  ...Object.fromEntries(ADJUSTMENTS.map((key) => [key, 0])),
});

// Whether the positive carries colour, and so whether warmth and tint mean anything.
export function carriesColour(recipe, films) {
  if (recipe.conversion !== "film") return !recipe.monochrome;
  return films.find(({ id }) => id === recipe.stockID)?.monochrome !== true;
}

export const filmOf = (recipe, films) =>
  recipe.conversion === "film" ? films.find(({ id }) => id === recipe.stockID) : null;

// NegativeScanRecipe.paper(for:): the chosen receiver where the film offers it, else its first.
export function paperOf(recipe, films) {
  const papers = filmOf(recipe, films)?.papers ?? [];
  return papers.find(({ id }) => id === recipe.paperID) ?? papers[0] ?? null;
}

// NegativeScanRecipe.adoptConversion: another frame's reading, printing and tone, this frame's
// own framing.
export function adoptConversion(recipe, other) {
  const { quarterTurns, mirrored, straighten, crop, attachments } = recipe;
  return { ...other, quarterTurns, mirrored, straighten, crop, attachments };
}

// Stroke-aware history: a drag's run of edits is one step, as NegativeScanSession keeps it.
export function createHistory(recipe) {
  return { recipe, undo: [], redo: [], strokeBase: null };
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

export function historyReducer(state, action) {
  switch (action.type) {
    case "reset":
      return createHistory(action.recipe);
    case "edit": {
      const next = action.change(state.recipe);
      if (same(next, state.recipe)) return state;
      // A stroke remembers where it began when it ends; a single edit remembers it now.
      if (action.stroke) {
        return { ...state, recipe: next, strokeBase: state.strokeBase ?? state.recipe };
      }
      return {
        recipe: next,
        undo: [...state.undo, state.recipe].slice(-100),
        redo: [],
        strokeBase: null,
      };
    }
    case "endStroke": {
      const base = state.strokeBase;
      if (!base) return state;
      if (same(base, state.recipe)) return { ...state, strokeBase: null };
      return {
        ...state,
        undo: [...state.undo, base].slice(-100),
        redo: [],
        strokeBase: null,
      };
    }
    case "undo": {
      const previous = state.undo.at(-1);
      if (!previous) return state;
      return {
        recipe: previous,
        undo: state.undo.slice(0, -1),
        redo: [...state.redo, state.recipe],
        strokeBase: null,
      };
    }
    case "redo": {
      const next = state.redo.at(-1);
      if (!next) return state;
      return {
        recipe: next,
        undo: [...state.undo, state.recipe],
        redo: state.redo.slice(0, -1),
        strokeBase: null,
      };
    }
    default:
      return state;
  }
}

// A conversion copied to paste onto the next frame of the roll, kept on this device.
const COPIED = "fotufilm.negative-scan.copied-conversion";

export function copyConversion(recipe, storage = globalThis.localStorage) {
  storage?.setItem(COPIED, JSON.stringify(recipe));
}

export function copiedConversion(storage = globalThis.localStorage) {
  try {
    const text = storage?.getItem(COPIED);
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}
