import { loadFilmProfile } from "./film-profile.js";

export const perspectiveIsActive = (edit) =>
  Math.abs(edit.perspectiveV || 0) > 0.001 ||
  Math.abs(edit.perspectiveH || 0) > 0.001;
export async function loadPerspective(image, edit, onProgress) {
  if (!perspectiveIsActive(edit)) return null;
  const swapped = edit.rotation % 2 !== 0;
  const request = {
    kind: "perspective",
    width: swapped ? image.naturalHeight : image.naturalWidth,
    height: swapped ? image.naturalWidth : image.naturalHeight,
    vertical: edit.perspectiveV || 0,
    horizontal: edit.perspectiveH || 0,
  };
  const plan = JSON.parse(
    new TextDecoder().decode(await loadFilmProfile(request, onProgress)),
  );
  if (
    !Array.isArray(plan.inverse) ||
    plan.inverse.length !== 8 ||
    !plan.inverse.every(Number.isFinite)
  )
    throw new Error("Invalid perspective correction.");
  return plan.inverse;
}
