import { useEffect, useState } from "react";
import { useBackend } from "./backend/BackendContext.jsx";
import { createImageScope } from "./backend/image-scope.js";
import { createNegativeLivePreview } from "./negative-live-preview.js";
const initialStatus = "Choose an unadjusted image or camera RAW negative.";

// The dialog's owner: the scan and its live preview, which outlive any one edit.
export function useNegativePreview(file, open, session) {
  const backend = useBackend();
  const [decoded, setDecoded] = useState(null),
    [live, setLive] = useState(null);
  const [plan, setPlan] = useState(null),
    [negative, setNegative] = useState(false);
  const [status, setStatus] = useState(initialStatus),
    [error, setError] = useState(null);
  useEffect(() => {
    if (open) return;
    setDecoded(null);
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
  // One live preview per scan keeps its analyses and positive between edits.
  useEffect(() => {
    if (!open || !decoded || !session) return;
    const scope = createImageScope(backend),
      preview = createNegativeLivePreview({
        backend,
        session,
        scan: decoded,
        scope,
      });
    setLive(preview);
    setStatus("Analysing negative…");
    return () => {
      preview.close();
      scope.dispose();
      setLive(null);
    };
  }, [backend, decoded, open, session]);
  return {
    decoded,
    live,
    plan,
    setPlan,
    negative,
    setNegative,
    status,
    setStatus,
    error,
    setError,
  };
}

// The dialog's live positive. A new frame re-renders only the dialog; the owner
// hears only when the analysis behind the frames changes. Frames arrive in
// request order, so each finished one is shown while a drag continues.
export function useLivePositive(model, settings) {
  const { live, setPlan, setStatus, setError } = model;
  const [frame, setFrame] = useState(null);
  useEffect(() => setFrame(null), [live]);
  useEffect(() => {
    if (!live) return;
    live
      .render(settings)
      .then((next) => {
        if (next && !live.closed) setFrame(next);
      })
      .catch((error) => {
        if (live.closed) return;
        setError(error.message);
        setStatus("");
      });
  }, [live, settings, setError, setStatus]);
  const plan = frame?.plan;
  useEffect(() => {
    if (!plan) return;
    setPlan(plan);
    setError(null);
    setStatus(
      plan.weak
        ? "Limited tonal range: review the preview before importing."
        : "Positive ready. You can adjust crop, colour and tone after importing.",
    );
  }, [plan, setPlan, setError, setStatus]);
  return frame;
}
