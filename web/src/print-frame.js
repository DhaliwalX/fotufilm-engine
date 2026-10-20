import { editorControl } from "./editor-catalogue.js";
import { PROFILE_MENUS } from "./generated/controls.js";

export const frameChoices = () => editorControl("printFrame").choices;
export function parsePrintFrame(value) {
  if (value == null) return "none";
  if (!frameChoices().some((choice) => choice.id === value))
    throw new Error("Invalid print frame.");
  return value;
}
// Border Width, a multiple of the frame's preset margin. Older edits have none and keep the preset.
export function parsePrintFrameMargin(value) {
  if (value == null) return 1;
  const { min, max } = editorControl("printFrameMargin").scale;
  if (!Number.isFinite(value) || value < min || value > max)
    throw new Error("Invalid print frame border width.");
  return value;
}
// A Film Border's frame number, 0 to 38 (Frame Number); older edits have none and show frame 1.
export function parsePrintFrameNumber(value) {
  if (value == null) return 1;
  if (!editorControl("printFrameNumber").choices.some((c) => c.value === value))
    throw new Error("Invalid film border frame number.");
  return value;
}
// Whether a Film Border shows the stock's edge printing (Edge Printing); older edits show it.
export function parsePrintFrameEdgePrinting(value) {
  if (value == null) return true;
  if (typeof value !== "boolean") throw new Error("Invalid film border edge printing.");
  return value;
}
export function frameRequest(edit, width = 1, height = 1) {
  return {
    kind: "print-frame",
    stock: edit.stock,
    frame: edit.printFrame || "none",
    format: edit.format || null,
    medium: edit.medium || null,
    margin: edit.printFrameMargin ?? 1,
    frameNumber: edit.printFrameNumber ?? 1,
    edgePrinting: edit.printFrameEdgePrinting ?? true,
    viewingKelvin:
      PROFILE_MENUS.printLight.find((c) => c.id === edit.profile?.printLight)
        ?.value ?? null,
    width,
    height,
  };
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
// A Film Border develops its whole strip with the photograph (`plan.strip`, from
// PrintFramePlacement.filmStrip): the photograph continued past its edges over the larger piece
// of film, as UnexposedEdge.extend does natively. The gate the profile carries shades it there.
export function stripSource(source, strip) {
  const width = source.width + strip.left + strip.right,
    height = source.height + strip.top + strip.bottom;
  const clampX = (x) => Math.min(Math.max(x - strip.left, 0), source.width - 1),
    clampY = (y) => Math.min(Math.max(y - strip.top, 0), source.height - 1);
  return {
    width,
    height,
    read(x, y, w, h) {
      const x0 = clampX(x),
        x1 = clampX(x + w - 1),
        y0 = clampY(y),
        y1 = clampY(y + h - 1);
      const sw = x1 - x0 + 1;
      const extend = (inner) => {
        const out = new inner.constructor(w * h * 4);
        for (let row = 0; row < h; row++) {
          const from = (clampY(y + row) - y0) * sw * 4;
          for (let column = 0; column < w; column++) {
            const i = from + (clampX(x + column) - x0) * 4,
              o = (row * w + column) * 4;
            out[o] = inner[i];
            out[o + 1] = inner[i + 1];
            out[o + 2] = inner[i + 2];
            out[o + 3] = inner[i + 3];
          }
        }
        return out;
      };
      const inner = source.read(x0, y0, sw, y1 - y0 + 1);
      return inner && typeof inner.then === "function" ? inner.then(extend) : extend(inner);
    },
  };
}
