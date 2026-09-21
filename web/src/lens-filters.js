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
  const filters = edit.filters || [];
  if (!filters.length)
    return "Filters change the light before it reaches the film. Color filters change its color, neutral density filters reduce it, and diffusion filters soften highlights.";
  const lines = [];
  if (filters.filter(isDiffusion).length > 1)
    lines.push(
      "Only the first diffusion filter acts; the rest are ignored, because two halos compose as a convolution of their profiles and not as a product of their numbers.",
    );
  if (filters.some((id) => !isDiffusion(id)))
    lines.push(
      {
        none: "Exposure stays fixed, so the filters make the image darker.",
        throughTheLens:
          "Compensates for light lost through the filters as a camera meter would. Neutral density is fully compensated; strong color filters can still underexpose.",
        filmSpeed:
          "Compensates using the filter factor for this film. This restores exposure in the green-sensitive layer.",
      }[edit.filterMetering || "throughTheLens"],
    );
  return lines.join("\n\n");
}

export function filterSwatch(id) {
  const choice = filterChoice(id);
  if (!choice?.spectrum) return undefined;
  const colors = choice.spectrum.map((rgb) => `rgb(${rgb.join(" ")})`);
  return `linear-gradient(to right, ${colors.join(", ")})`;
}
