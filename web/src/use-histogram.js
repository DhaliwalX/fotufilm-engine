import { useEffect, useRef, useState } from "react";

export function useHistogram(result, open) {
  const frameResult = useRef(null),
    worker = useRef(null),
    generation = useRef(0);
  const [snapshot, setSnapshot] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    if (!open) return;
    const instance = new Worker(
      new URL("./histogram.worker.js", import.meta.url),
      { type: "module" },
    );
    worker.current = instance;
    instance.onmessage = ({ data }) => {
      if (data.generation !== generation.current) return;
      if (data.error) setError(data.error);
      else
        setSnapshot({ analysis: data.analysis, result: frameResult.current });
    };
    instance.onerror = () => setError("Histogram analysis could not start.");
    return () => {
      worker.current = null;
      instance.terminate();
    };
  }, [open]);
  useEffect(() => {
    const id = ++generation.current;
    frameResult.current = result;
    setSnapshot(null);
    setError(null);
    if (open && result?.blob && worker.current)
      worker.current.postMessage({
        generation: id,
        output: result.blob,
        colorSpace: result.colorSpace || "srgb",
      });
  }, [result, open]);
  // Never associate counts from an older render with the current photo.
  return {
    analysis: open && snapshot?.result === result ? snapshot.analysis : null,
    error,
  };
}
