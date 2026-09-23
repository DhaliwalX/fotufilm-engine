import { useEffect, useState } from "react";
import { useBackend } from "./backend/BackendContext.jsx";
import { createImageScope } from "./backend/image-scope.js";
const initialStatus = "Choose an unadjusted image or camera RAW negative.";

export function useNegativePreview(file, monochrome, open) {
  const backend = useBackend();
  const [decoded, setDecoded] = useState(null),
    [positive, setPositive] = useState(null);
  const [plan, setPlan] = useState(null),
    [negative, setNegative] = useState(false);
  const [status, setStatus] = useState(initialStatus),
    [error, setError] = useState(null);
  useEffect(() => {
    if (open) return;
    setDecoded(null);
    setPositive(null);
    setPlan(null);
    setNegative(false);
    setStatus(initialStatus);
    setError(null);
  }, [open]);
  useEffect(() => {
    if (!open || !file) return;
    const controller = new AbortController(),
      scope = createImageScope(backend);
    setDecoded(null);
    setPositive(null);
    setPlan(null);
    setError(null);
    setStatus("Reading negative…");
    async function run() {
      const result = await backend.importMedia(file, {
        signal: controller.signal,
        onProgress: (text) => {
          if (!controller.signal.aborted) setStatus(text);
        },
        negative: true,
      });
      scope.image(result.image);
      scope.preview(result);
      if (!controller.signal.aborted) setDecoded(result.image);
    }
    run().catch((error) => {
      scope.dispose();
      if (!controller.signal.aborted) {
        setError(error.message);
        setStatus("");
      }
    });
    return () => {
      controller.abort();
      scope.dispose();
    };
  }, [backend, file, open]);
  useEffect(() => {
    if (!open || !decoded) return;
    const controller = new AbortController(),
      scope = createImageScope(backend);
    setPlan(null);
    setPositive(null);
    setError(null);
    setStatus("Analysing negative…");
    async function run() {
      const analysis = await backend.analyseNegative(decoded, monochrome);
      if (controller.signal.aborted) return;
      const result = await backend.convertNegative(decoded, analysis, {
        signal: controller.signal,
        maxEdge: 1200,
        onProgress: () => {
          if (!controller.signal.aborted)
            setStatus("Rendering positive preview…");
        },
      });
      scope.image(result.image);
      if (controller.signal.aborted) return;
      const preview = await backend.makePreview(result.image, {
        signal: controller.signal,
      });
      scope.preview(preview);
      if (controller.signal.aborted) return;
      setPlan(analysis);
      setPositive(preview.image);
      setNegative(false);
      setStatus(
        analysis.weak
          ? "Limited tonal range: review the preview before importing."
          : "Positive ready. You can adjust crop, colour and tone after importing.",
      );
    }
    run().catch((error) => {
      scope.dispose();
      if (!controller.signal.aborted) {
        setError(error.message);
        setStatus("");
      }
    });
    return () => {
      controller.abort();
      scope.dispose();
    };
  }, [backend, decoded, monochrome, open]);
  return {
    decoded,
    positive,
    plan,
    negative,
    setNegative,
    status,
    setStatus,
    error,
    setError,
  };
}
