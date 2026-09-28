import { useEffect, useState } from "react";
import { useAppSetting } from "../app-settings.js";

// The export sheet's names for each metadata policy (ExportMetadataPolicy in the Mac app).
export const METADATA_LABELS = {
  preserve: "Include Location",
  preserveWithoutLocation: "Capture Details",
  strip: "No Metadata",
};

/**
 * What the backend can write for this edit beyond the format list: metadata policies, HDR HEIC
 * and which of `sizes` (`{id, pixels}`) exceed its memory limit (`unavailable`). Null while
 * unknown, and always for backends that do not say.
 */
export function useExportOptions({ backend, active, edit, stockId, sizes = [] }) {
  const [options, setOptions] = useState(null);
  const photoQuality = useAppSetting("photoQuality");
  // The sizes by value: the dialog lists them afresh on every render.
  const sizeKey = JSON.stringify(
    sizes.filter(({ pixels }) => pixels).map(({ id, pixels }) => ({ id, ...pixels })),
  );
  useEffect(() => {
    if (!backend.exportOptions || !active || active.image.video) {
      setOptions(null);
      return;
    }
    let current = true;
    backend
      .exportOptions({
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: 1024,
        sizes: JSON.parse(sizeKey),
        photoQuality,
      })
      .then((answer) => current && setOptions(answer))
      .catch(() => current && setOptions(null));
    return () => {
      current = false;
    };
  }, [backend, active, edit, stockId, sizeKey, photoQuality]);
  return options;
}
