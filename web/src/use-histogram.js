import { useEffect, useRef, useState } from "react";
import { useBackend } from "./backend/BackendContext.jsx";

export function useHistogram(result, open) {
  const backend = useBackend(),
    analyser = useRef(null);
  const [snapshot, setSnapshot] = useState(null),
    [error, setError] = useState(null);
  useEffect(() => {
    if (!open) return;
    try {
      analyser.current = backend.createHistogram();
    } catch (error) {
      setError(error.message);
      return;
    }
    const instance = analyser.current;
    return () => {
      analyser.current = null;
      instance.dispose();
    };
  }, [backend, open]);
  useEffect(() => {
    const controller = new AbortController();
    setSnapshot(null);
    if (open && result?.blob && analyser.current) {
      setError(null);
      const instance = analyser.current;
      Promise.resolve()
        .then(() => {
          if (!controller.signal.aborted)
            return instance.analyse(result, { signal: controller.signal });
        })
        .then((analysis) => {
          if (!controller.signal.aborted) setSnapshot({ analysis, result });
        })
        .catch((error) => {
          if (!controller.signal.aborted && error.name !== "AbortError")
            setError(error.message);
        });
    }
    return () => controller.abort();
  }, [backend, result, open]);
  // Never associate counts from an older render with the current photo.
  return {
    analysis: open && snapshot?.result === result ? snapshot.analysis : null,
    error,
  };
}
