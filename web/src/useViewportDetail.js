import { useEffect, useRef, useState } from "react";
import { PreviewQueue } from "./preview-queue.js";
import { renderViewportImage } from "./viewport-detail-image.js";

// Wait for 300 ms without movement, then render only the latest viewport.
// Keep the last decoded surface visible and bound work to one active + one pending.
export function useViewportDetail({
  session,
  request,
  viewport,
  enabled,
  onError,
  onBackend,
}) {
  const [detail, setDetail] = useState(null);
  const work = useRef(null);
  const surfaces = useRef(new Set());
  const callbacks = useRef({ onError, onBackend });
  callbacks.current = { onError, onBackend };
  const viewportKey = JSON.stringify(viewport);

  useEffect(() => {
    if (!enabled || !session || !request) return;
    const current = { queue: new PreviewQueue(), cancelled: false };
    work.current = current;
    return () => {
      current.cancelled = true;
      current.queue.close();
      work.current = null;
      setDetail(null);
      callbacks.current.onBackend?.(null);
    };
  }, [session, request, enabled]);

  useEffect(() => {
    const current = work.current;
    if (!current) return;
    current.latest = viewportKey;
    if (!viewportKey || viewportKey === "null") return;
    const timer = setTimeout(() => {
      current.queue
        .submit(async () => {
          if (current.cancelled || current.latest !== viewportKey) return;
          const next = await renderViewportImage(
            session,
            request,
            JSON.parse(viewportKey),
            () => current.cancelled || current.latest !== viewportKey,
          );
          if (!next) return;
          surfaces.current.add(next);
          setDetail(next);
          callbacks.current.onBackend?.(next.backend);
        })
        .catch((error) => {
          if (!current.cancelled && current.latest === viewportKey)
            callbacks.current.onError?.(
              error.message || "Visible image refinement failed.",
            );
        });
    }, 300);
    return () => clearTimeout(timer);
  }, [session, request, viewportKey, enabled]);

  // Release the old surface only after React commits its decoded replacement.
  useEffect(() => {
    for (const surface of surfaces.current) {
      if (surface === detail) continue;
      surface.dispose();
      surfaces.current.delete(surface);
    }
  }, [detail]);
  useEffect(
    () => () => {
      for (const surface of surfaces.current) surface.dispose();
      surfaces.current.clear();
    },
    [],
  );
  return enabled && detail?.request === request ? detail : null;
}
