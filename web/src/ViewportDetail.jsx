import { useEffect, useState } from "react";
import { viewportPlacement } from "./viewport.js";

// A small overview stays mounted under this surface during gestures. A new
// region replaces it only after movement settles and its development finishes.
export default function ViewportDetail({
  session,
  request,
  viewport,
  enabled,
  compare,
  onError,
  onBackend,
}) {
  const [detail, setDetail] = useState(null);
  const viewportKey = JSON.stringify(viewport);
  useEffect(() => {
    if (!enabled || !session || !viewportKey || viewportKey === "null") return;
    let cancelled = false;
    const urls = [];
    const visible = JSON.parse(viewportKey);
    session
      .render({
        ...request,
        viewport: visible,
        purpose: "visible detail",
        stale: () => cancelled,
      })
      .then((result) => {
        if (!result || cancelled) return;
        onBackend?.(result.backend);
        const url = URL.createObjectURL(result.blob);
        const originalUrl = URL.createObjectURL(result.original);
        urls.push(url, originalUrl);
        setDetail({
          url,
          originalUrl,
          viewport: visible,
          request,
          backend: result.backend,
        });
      })
      .catch((error) => {
        // The overview remains usable if the optional refinement fails.
        if (!cancelled)
          onError?.(error.message || "Visible image refinement failed.");
      });
    return () => {
      cancelled = true;
      for (const url of urls) URL.revokeObjectURL(url);
      setDetail(null);
      onBackend?.(null);
    };
  }, [session, request, viewportKey, enabled, onError, onBackend]);
  if (!detail || detail.request !== request || !enabled) return null;
  return (
    <div className="viewport-detail-surface">
      <img
        className="viewport-detail"
        src={compare ? detail.originalUrl : detail.url}
        alt=""
        aria-hidden="true"
        draggable="false"
        data-render-width={detail.viewport.region.width}
        data-render-height={detail.viewport.region.height}
        data-frame-width={detail.viewport.width}
        data-frame-height={detail.viewport.height}
        data-backend={detail.backend}
        style={viewportPlacement(detail.viewport)}
      />
    </div>
  );
}
