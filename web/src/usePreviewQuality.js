import { useEffect, useState } from "react";

// Include zoom and pointer-held movement in the same settling policy as edits.
// A detail request becomes obsolete immediately when any of these changes.
export function usePreviewQuality(identity, moving, delay = 300) {
  const [settled, setSettled] = useState(null);
  useEffect(() => {
    if (moving) {
      setSettled(null);
      return;
    }
    const timer = setTimeout(() => setSettled(identity), delay);
    return () => clearTimeout(timer);
  }, [identity, moving, delay]);
  return moving || settled !== identity;
}
