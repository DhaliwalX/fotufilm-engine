import { LENS_FILTERS } from "./generated/controls.js";

export const filterChoice = (id) =>
  LENS_FILTERS.choices.find((c) => c.id === id);
export const isDiffusion = (id) =>
  LENS_FILTERS.supported.includes(id) && /-/.test(id);
export function parseLensFilters(edit) {
  const filters = edit.filters ?? [];
  const filterMetering = edit.filterMetering ?? "throughTheLens";
  if (
    !Array.isArray(filters) ||
    !filters.every((id) => LENS_FILTERS.supported.includes(id)) ||
    !LENS_FILTERS.meterings.some((choice) => choice.id === filterMetering)
  )
    throw new Error("Invalid lens filters.");
  return { filters: [...filters], filterMetering };
}
export function filterNote(edit) {
  const diffusion = (edit.filters || []).filter(isDiffusion).length;
  return diffusion > 1 ? "Only the first diffusion filter acts." : "";
}

export function filterSwatch(id) {
  const choice = filterChoice(id);
  if (!choice?.spectrum) return undefined;
  const colors = choice.spectrum.map((rgb) => `rgb(${rgb.join(" ")})`);
  return `linear-gradient(to right, ${colors.join(", ")})`;
}
