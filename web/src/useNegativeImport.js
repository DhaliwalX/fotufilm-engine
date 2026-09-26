import { useEffect, useRef, useState } from "react";
import { useBackend } from "./backend/BackendContext.jsx";
import { createImageScope } from "./backend/image-scope.js";
import { useNegativePreview } from "./useNegativePreview.js";

// The scan and the import live with the editor; the dialog owns its settings, so
// moving a slider re-renders only the dialog.
export default function useNegativeImport(onImport, open, session) {
  const backend = useBackend();
  const [file, setFile] = useState(null),
    [busy, setBusy] = useState(false),
    finalController = useRef(null);
  const preview = useNegativePreview(file, open, session);
  const { decoded, live, plan, setStatus, setError } = preview;
  // DialogContainer can retain its child after closing. The owner tracks visibility
  // outside that container so native resources and work do not survive dismissal.
  useEffect(() => {
    if (!open) {
      setFile(null);
      setBusy(false);
    }
    return () => finalController.current?.abort();
  }, [open]);
  async function importPositive(settings) {
    if (!plan || busy) return;
    const controller = new AbortController(),
      scope = createImageScope(backend);
    finalController.current = controller;
    setBusy(true);
    setError(null);
    try {
      const chosen = await live.plan(settings.monochrome);
      const result = await backend.convertNegative(decoded, chosen, {
        contrast: settings.contrast,
        signal: controller.signal,
        onProgress: ({ progress }) => {
          if (!controller.signal.aborted)
            setStatus(
              `Converting full resolution… ${Math.round(progress * 100)}%`,
            );
        },
      });
      scope.image(result.image);
      if (controller.signal.aborted) return;
      const completed = await backend.makePreview(result.image, {
        signal: controller.signal,
      });
      scope.preview(completed);
      if (controller.signal.aborted) return;
      onImport(
        {
          ...completed,
          name: `${file.name} — Positive`,
          id: crypto.randomUUID(),
        },
        settings,
      );
      scope.transfer(completed.image, completed.url);
    } catch (error) {
      if (!controller.signal.aborted) {
        setError(error.message);
        setBusy(false);
        setStatus("");
      }
    } finally {
      scope.dispose();
    }
  }
  return {
    ...preview,
    file,
    setFile,
    busy,
    importPositive,
  };
}
