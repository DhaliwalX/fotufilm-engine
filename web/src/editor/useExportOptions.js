import { useEffect, useState } from "react";

// The export sheet's names for each metadata policy (ExportMetadataPolicy in the Mac app).
export const METADATA_LABELS = {
  preserve: "Include Location",
  preserveWithoutLocation: "Capture Details",
  strip: "No Metadata",
};

/**
 * What the backend can write for this edit beyond the format list: metadata policies and HDR
 * HEIC. Null while unknown, and always for backends that do not say.
 */
export function useExportOptions({ backend, active, edit, stockId }) {
  const [options, setOptions] = useState(null);
  useEffect(() => {
    if (!backend.exportOptions || !active || active.image.video) {
      setOptions(null);
      return;
    }
    let current = true;
    backend
      .exportOptions({ image: active.image, edit, stock: stockId, maxEdge: 1024 })
      .then((answer) => current && setOptions(answer))
      .catch(() => current && setOptions(null));
    return () => {
      current = false;
    };
  }, [backend, active, edit, stockId]);
  return options;
}
