// The grade deck's arithmetic, as the native Mac app's:
// a two-axis pad, warm against cool across and green against magenta up, and a level under it.

export const GRADE_BANDS = ["Shadows", "Midtones", "Highlights"];
const AXES = ["Warmth", "Tint", "Level"];

/** The edit fields of a band: `{warmth, tint, level}`. */
export const gradeFields = (band) =>
  Object.fromEntries(AXES.map((axis) => [axis.toLowerCase(), `grade${band}${axis}`]));

/** Every grade field of every band. */
export const GRADE_FIELDS = GRADE_BANDS.flatMap((band) => Object.values(gradeFields(band)));

/** Whether the edit's grade is the neutral one, which Reset Grade has nothing to do to. */
export const gradeIsNeutral = (params = {}) => GRADE_FIELDS.every((key) => !params[key]);

/** The name of the colour a balance is tilted toward. */
export function gradeCast(x, y) {
  const horizontal = x > 0 ? "Warm" : "Cool";
  const vertical = y > 0 ? "Green" : "Magenta";
  if (x && y)
    return Math.abs(x) >= Math.abs(y)
      ? `${horizontal} ${vertical.toLowerCase()}`
      : `${vertical} ${horizontal.toLowerCase()}`;
  return x ? horizontal : vertical;
}

// "%+.0f" of a hundredth, as the Mac app prints a level.
const signed = (value) => {
  const rounded = Math.round(value * 100);
  return `${rounded < 0 ? "-" : "+"}${Math.abs(rounded)}`;
};

/** The reading beside a band's name: its cast and level, empty when neutral. */
export function gradeReadout({ warmth = 0, tint = 0, level = 0 }) {
  const parts = [];
  if (warmth || tint) parts.push(gradeCast(warmth, tint));
  if (level) parts.push(signed(level));
  return parts.join(" · ");
}

/** The pad's reading for anyone listening rather than looking. */
export const padReading = (warmth, tint) =>
  warmth || tint ? gradeCast(warmth, tint) : "Neutral";

export const levelReading = (level) => signed(level);

const clamp1 = (value) => Math.min(Math.max(value, -1), 1);

/**
 * The balance a point on a pad `width` x `height` sets, `inset` in from its edges; within 6% of
 * the centre it snaps to neutral. Up is green: y grows downward on the page.
 */
export function padBalance(x, y, width, height, inset = 18) {
  const spanX = width / 2 - inset;
  const spanY = height / 2 - inset;
  if (!(spanX > 0 && spanY > 0)) return null;
  const warmth = clamp1((x - width / 2) / spanX);
  const tint = clamp1((height / 2 - y) / spanY);
  if (Math.abs(warmth) < 0.06 && Math.abs(tint) < 0.06) return { warmth: 0, tint: 0 };
  return { warmth, tint };
}

/** Where the knob of a balance sits on the pad. */
export const padPoint = (warmth, tint, width, height, inset = 18) => ({
  x: width / 2 + warmth * (width / 2 - inset),
  y: height / 2 - tint * (height / 2 - inset),
});

/** The level a point along a capsule `width` x `height` sets; within 4% of neutral it snaps. */
export function capsuleLevel(x, width, height) {
  const usable = Math.max(width - height, 1);
  const fraction = Math.min(Math.max((x - height / 2) / usable, 0), 1);
  const level = fraction * 2 - 1;
  return Math.abs(level) < 0.04 ? 0 : level;
}
