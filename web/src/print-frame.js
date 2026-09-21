import { editorControl } from "./editor-catalogue.js";
import { PROFILE_MENUS } from "./generated/controls.js";
import { loadFilmProfile } from "./film-profile.js";

export const frameChoices = () => editorControl("printFrame").choices;
export function parsePrintFrame(value) {
  if (value == null) return "none";
  if (!frameChoices().some((choice) => choice.id === value))
    throw new Error("Invalid print frame.");
  return value;
}
export function frameRequest(edit, width = 1, height = 1) {
  return {
    kind: "print-frame",
    stock: edit.stock,
    frame: edit.printFrame || "none",
    format: edit.format || null,
    medium: edit.medium || null,
    viewingKelvin:
      PROFILE_MENUS.printLight.find((c) => c.id === edit.profile?.printLight)
        ?.value ?? null,
    width,
    height,
  };
}
export async function loadPrintFrame(edit, width = 1, height = 1, onProgress) {
  return JSON.parse(
    new TextDecoder().decode(
      await loadFilmProfile(frameRequest(edit, width, height), onProgress),
    ),
  );
}
export function frameRenderEdit(edit, plan) {
  if (!plan || plan.configuration.frame === "none") return edit;
  const transparency = ["film", "slideMount"].includes(
    plan.configuration.frame,
  );
  return {
    ...edit,
    medium: plan.renderMedium || edit.medium,
    profile: {
      ...edit.profile,
      ...(transparency ? { printLight: "reference" } : {}),
      ...(plan.renderMedium === "negative"
        ? { negativeViewing: "light-box" }
        : {}),
    },
  };
}
// Selection samples remain in photograph coordinates. A click in the surrounding material
// does not pick a colour from the photo, even when the canvas is zoomed or rotated.
export function frameSamplePoint(point, plan) {
  if (!plan) return point;
  const { size, image } = plan.placement;
  const x = (point[0] * size.width - image.x) / image.width;
  const y =
    (point[1] * size.height - (size.height - image.y - image.height)) /
    image.height;
  return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? [x, y] : null;
}
