import { useEffect, useRef } from "react";
import { useBackend } from "../backend/BackendContext.jsx";
import { frameSamplePoint } from "../print-frame.js";
import { newSelection } from "../selective.js";

export function useSceneSampling({
  shownResult,
  sampling,
  edit,
  patch,
  setSampling,
  setError,
}) {
  const backend = useBackend(),
    current = useRef(null),
    generation = useRef(0);
  current.current = { shownResult, edit, sampling };
  useEffect(
    () => () => {
      generation.current++;
      current.current = null;
    },
    [],
  );
  return async (point) => {
    if (!shownResult) return;
    point = frameSamplePoint(point, shownResult.framePlan);
    if (!point) return;
    const id = ++generation.current;
    const valid = () =>
      id === generation.current &&
      current.current?.sampling &&
      current.current?.shownResult === shownResult &&
      current.current?.edit === edit;
    try {
      // Film Base: clear film on a scanned negative, which the scan is read against.
      if (sampling === "filmBase") {
        const border = await backend.negativeScans.sampleFilmBase(shownResult, point);
        if (!valid()) return;
        patch({ negative: { ...edit.negative, border } });
        setSampling(false);
        return;
      }
      const sample = await backend.sampleScene(shownResult, point);
      if (!sample || !valid()) return;
      patch({
        selective: { ...(edit.selective || newSelection(edit)), point, sample },
      });
      setSampling(false);
    } catch (error) {
      if (valid()) setError(error.message);
    }
  };
}
