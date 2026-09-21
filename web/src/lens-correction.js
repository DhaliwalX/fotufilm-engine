export const lensFields = {
  lensDistortion: "distortion",
  lensVignetting: "vignetting",
  lensRedCyan: "redCyan",
  lensBlueYellow: "blueYellow",
};
export const defaultLens = () => ({
  enabled: false,
  amount: 1,
  profileID: null,
  distortion: 0,
  vignetting: 0,
  redCyan: 0,
  blueYellow: 0,
});
export const hasLensAdjustments = (lens) =>
  (lens?.amount ?? 1) !== 1 ||
  lens?.profileID != null ||
  Object.values(lensFields).some((key) => (lens?.[key] ?? 0) !== 0);
export const lensIsActive = (lens) => !!lens?.enabled;

export function parseLensCorrection(value) {
  if (value == null) return defaultLens();
  if (
    typeof value.enabled !== "boolean" ||
    (value.amount != null &&
      (!Number.isFinite(value.amount) ||
        value.amount < 0 ||
        value.amount > 1)) ||
    (value.profileID != null &&
      (typeof value.profileID !== "string" ||
        !value.profileID.length ||
        value.profileID.length > 1024)) ||
    Object.values(lensFields).some(
      (key) => !Number.isFinite(value[key]) || Math.abs(value[key]) > 1,
    )
  ) {
    throw new Error("Invalid lens correction settings.");
  }
  return {
    enabled: value.enabled,
    amount: value.amount ?? 1,
    profileID: value.profileID ?? null,
    ...Object.fromEntries(
      Object.values(lensFields).map((key) => [key, value[key]]),
    ),
  };
}

export function lensRequest(lens) {
  const value = parseLensCorrection(lens);
  return {
    kind: "lens",
    adjustment: Object.fromEntries(
      Object.values(lensFields).map((key) => [key, value[key]]),
    ),
  };
}

export function readLensTable(bytes) {
  if (!(bytes instanceof ArrayBuffer) || bytes.byteLength !== 1024 * 4 * 4)
    throw new Error("Invalid lens correction table.");
  const view = new DataView(bytes);
  const table = Float32Array.from({ length: 4096 }, (_, i) =>
    view.getFloat32(i * 4, true),
  );
  if (!table.every(Number.isFinite))
    throw new Error("Invalid lens correction table.");
  return table;
}

// Same half-diagonal normalization and linear table lookup as LensCorrectionFilter.
// Return pixel coordinates (pixel centers are integers) and the light gain.
export function lensSample(table, u, v, width, height, channel) {
  const x = (u - 0.5) * width,
    y = (v - 0.5) * height;
  const t =
    Math.min(1, Math.hypot(x, y) / (Math.hypot(width, height) / 2)) *
    (table.length / 4 - 1);
  const lo = Math.floor(t),
    hi = Math.min(lo + 1, table.length / 4 - 1),
    f = t - lo;
  const at = (c) => table[lo * 4 + c] * (1 - f) + table[hi * 4 + c] * f;
  const ratio = at(channel);
  return [width / 2 + x * ratio - 0.5, height / 2 + y * ratio - 0.5, at(3)];
}
