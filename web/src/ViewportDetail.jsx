import { useViewportDetail } from "./useViewportDetail.js";
import { viewportPlacement } from "./viewport.js";

// The overview and last decoded detail stay visible while the next region renders.
export default function ViewportDetail({
  session,
  request,
  viewport,
  enabled,
  compare,
  onError,
  onBackend,
}) {
  const detail = useViewportDetail({
    session,
    request,
    viewport,
    enabled,
    onError,
    onBackend,
  });
  if (!detail) return null;
  return (
    <div className="viewport-detail-surface">
      <img
        className="viewport-detail"
        src={compare ? detail.originalUrl : detail.url}
        alt=""
        aria-hidden="true"
        draggable="false"
        data-region-x={detail.viewport.region.x}
        data-region-y={detail.viewport.region.y}
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
