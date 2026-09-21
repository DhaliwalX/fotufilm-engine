import {
  EDITOR_CONTROLS,
  FILM_FORMATS,
  PROFILE_MENUS,
} from "./generated/controls.js";

export const PROFILE_CONTROLS = EDITOR_CONTROLS.filter(
  (c) => c.webTransform === "profile",
).map((c) => ({
  ...c,
  choices: c.choices || PROFILE_MENUS[c.field],
}));
export const profileDefault = (c) =>
  c.scale?.neutral ??
  (c.curve
    ? c.curve.handles.map(() => c.curve.neutral)
    : c.kind === "toggle"
      ? c.restingOn
      : c.choices?.[0]?.id);
export const hasProfileSettings = (edit) =>
  !!edit.format ||
  Object.entries(edit.profile || {}).some(([field, value]) => {
    const control = PROFILE_CONTROLS.find((c) => c.field === field);
    return (
      control &&
      (field === "halationReturn" ||
        JSON.stringify(value) !== JSON.stringify(profileDefault(control)))
    );
  });
export const profileMedium = (edit, stock) =>
  stock?.profile?.media?.[edit.medium || stock.defaultMedium];
export function profileControl(c, edit, stock) {
  const medium = profileMedium(edit, stock);
  return {
    ...c,
    scale: stock?.profile?.scales?.[c.field] || c.scale,
    choices:
      c.field === "printLight"
        ? medium?.viewingLights || c.choices
        : stock?.profile?.choices?.[c.field] || c.choices,
  };
}
export function profileControlAvailable(c, edit, stock) {
  if (!stock?.available.includes(c.field)) return false;
  const medium = profileMedium(edit, stock);
  if (c.section === "printLamp") return !!medium?.enlarger;
  switch (c.field) {
    case "printLight":
      return (medium?.viewingLights.length || 0) > 1;
    case "screenExposure":
      return !!medium?.screenConversion;
    case "screenGrade":
      return (
        !!medium?.screenGrade && edit.digitalReference !== "reference-exposure"
      );
    case "printCorrection":
      return !!medium?.correction;
    case "negativeViewing":
      return !!medium?.negative;
    default:
      return true;
  }
}
export function profileRequestControls(edit, stock) {
  return Object.fromEntries(
    PROFILE_CONTROLS.filter(
      (c) =>
        profileControlAvailable(c, edit, stock) &&
        Object.hasOwn(edit.profile || {}, c.field),
    ).map((c) => {
      const active = profileControl(c, edit, stock),
        value = edit.profile[c.field];
      if (c.field === "push" && !active.scale.stops.includes(value))
        return [c.field, 0];
      if (
        active.choices &&
        !active.choices.some((choice) => choice.id === value)
      )
        return [c.field, profileDefault(active)];
      return [c.field, value];
    }),
  );
}
export function parseProfileSettings(edit) {
  if (edit.format != null && !FILM_FORMATS.some((f) => f.id === edit.format))
    throw new Error("Invalid film format.");
  if (
    edit.profile != null &&
    (typeof edit.profile !== "object" || Array.isArray(edit.profile))
  )
    throw new Error("Invalid film settings.");
  const profile = {};
  for (const [field, value] of Object.entries(edit.profile || {})) {
    const c = PROFILE_CONTROLS.find((c) => c.field === field);
    let valid = false;
    if (c?.scale)
      valid =
        Number.isFinite(value) &&
        value >= c.scale.admittedMin &&
        value <= c.scale.admittedMax;
    else if (c?.curve)
      valid =
        Array.isArray(value) &&
        value.length === c.curve.handles.length &&
        value.every(
          (v) => Number.isFinite(v) && v >= c.curve.min && v <= c.curve.max,
        );
    else if (c?.kind === "toggle") valid = typeof value === "boolean";
    else if (c?.choices)
      valid = c.choices.some((choice) => choice.id === value);
    if (!valid) throw new Error("Invalid film settings.");
    profile[field] = value;
  }
  return { format: edit.format ?? null, profile };
}
