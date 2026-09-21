import { EDITOR_CONTROLS, FILM_FORMATS } from "./generated/controls.js";

export const PROFILE_CONTROLS = EDITOR_CONTROLS.filter(
  (c) =>
    c.surfaces.includes("web") &&
    [
      "grainMottle",
      "grainModel",
      "expired",
      "halation",
      "halationColour",
    ].includes(c.field),
);
export const profileDefault = (c) => c.scale?.neutral ?? c.choices?.[0].id;
export const hasProfileSettings = (edit) =>
  !!edit.format ||
  Object.entries(edit.profile || {}).some(([field, value]) => {
    const control = PROFILE_CONTROLS.find((c) => c.field === field);
    return control && value !== profileDefault(control);
  });
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
    if (
      !c ||
      (c.scale
        ? !Number.isFinite(value) ||
          value < c.scale.admittedMin ||
          value > c.scale.admittedMax
        : !c.choices.some((choice) => choice.id === value))
    )
      throw new Error("Invalid film settings.");
    profile[field] = value;
  }
  return { format: edit.format ?? null, profile };
}
