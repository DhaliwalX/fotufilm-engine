import { defaultEdit, SLIDERS } from "./editor-state.js";
import { PreviewQueue } from "./preview-queue.js";

export const NEGATIVE_PREVIEW_EDGE = 1200;

// The positive is finished with the editor's own adjustments, so it arrives with
// them applied and they stay editable after import.
const ADJUSTMENT_KEYS = [
  "ev",
  "highlights",
  "shadows",
  "temperature",
  "tint",
  "saturation",
];
export const NEGATIVE_ADJUSTMENTS = ADJUSTMENT_KEYS.map((key) =>
  SLIDERS.find((slider) => slider.key === key),
);
const COLOUR_KEYS = new Set(["temperature", "tint", "saturation"]);
export const isColourAdjustment = (slider) => COLOUR_KEYS.has(slider.key);

// Contrast belongs to the conversion itself: the slope of its inverse sigmoid at
// mid-grey, in stops from the automatic default. Backends that support it say so.
export const NEGATIVE_CONTRAST = {
  key: "contrast",
  label: "Contrast",
  min: -1,
  max: 1,
  step: 0.01,
  def: 0,
};

export const defaultNegativeSettings = () => ({
  monochrome: false,
  contrast: NEGATIVE_CONTRAST.def,
  adjustments: Object.fromEntries(
    NEGATIVE_ADJUSTMENTS.map((slider) => [slider.key, slider.def]),
  ),
});

// A black-and-white positive keeps no colour adjustment.
export function negativeEdit({ monochrome, adjustments }) {
  const edit = defaultEdit(null),
    params = { ...edit.params };
  for (const slider of NEGATIVE_ADJUSTMENTS)
    if (!(monochrome && isColourAdjustment(slider)))
      params[slider.key] = adjustments[slider.key];
  return { ...edit, params };
}

// One scan's interactive conversion. Each black-and-white choice is analysed once
// and each contrast converted once; an adjustment only re-renders the positive.
// Renders run one at a time and only the newest request waits, so dragging a
// slider never queues stale positions.
export function createNegativeLivePreview({ backend, session, scan, scope }) {
  const plans = new Map(),
    queue = new PreviewQueue();
  let positive = null,
    closed = false;
  const plan = (monochrome) => {
    if (!plans.has(monochrome))
      plans.set(monochrome, backend.analyseNegative(scan, monochrome));
    return plans.get(monochrome);
  };
  async function convert(monochrome, contrast) {
    const key = `${monochrome}:${contrast}`;
    if (positive?.key === key) return positive.image;
    const { image } = await backend.convertNegative(
      scan,
      await plan(monochrome),
      { maxEdge: NEGATIVE_PREVIEW_EDGE, contrast },
    );
    scope.image(image);
    if (positive) scope.release(positive.image);
    positive = { key, image };
    return image;
  }
  return {
    plan,
    get closed() {
      return closed;
    },
    render({ monochrome, contrast, adjustments }) {
      return queue.submit(async () => {
        const image = await convert(monochrome, contrast);
        if (closed) return null;
        const result = await session.render({
          image,
          edit: negativeEdit({ monochrome, adjustments }),
          stock: null,
          maxEdge: NEGATIVE_PREVIEW_EDGE,
          comparison: false,
          purpose: "preview",
          stale: () => closed,
        });
        return (
          result && {
            blob: result.blob,
            colorSpace: result.colorSpace,
            plan: await plan(monochrome),
          }
        );
      });
    },
    close() {
      closed = true;
      queue.close();
    },
  };
}
