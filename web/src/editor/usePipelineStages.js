import { useEffect } from "react";
import { hasProfileSettings } from "../profile-settings.js";
export default function usePipelineStages({
  panel,
  session,
  stockId,
  setStages,
  edit,
  setError,
}) {
  useEffect(() => {
    if (panel !== "pipeline" || !session || !stockId) return;
    let cancelled = false;
    setStages([]);
    if (hasProfileSettings(edit)) return;
    session
      .stages(stockId, edit.medium, edit.halationModel, edit.digitalReference)
      .then((next) => {
        if (!cancelled) setStages(next);
      })
      .catch((e) => {
        if (!cancelled) setError(e.message);
      });
    return () => {
      cancelled = true;
    };
  }, [
    panel,
    session,
    stockId,
    edit.medium,
    edit.halationModel,
    edit.digitalReference,
    edit.format,
    edit.profile,
    edit.filters,
  ]);
}
