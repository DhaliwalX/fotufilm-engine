import { useEffect, useState } from "react";

// Track settled edits and viewer status. Viewport detail has its own debounce
// so a held pointer does not prevent refinement once its position stops changing.
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
