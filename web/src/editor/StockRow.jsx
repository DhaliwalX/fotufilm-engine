import StockButton from "./StockButton.jsx";
import { useThumbnail } from "./useThumbnail.js";

// A film's thumbnail is the photograph as that film would develop it under the edit it has now,
// as the Mac app's film column shows it: `edit` (settled by the caller) with only the film swapped.
// `stock` is null for Normal.
export function StockRow({
  stock,
  name = stock?.name,
  kind = stock?.kind || "Film",
  active,
  image,
  edit,
  videoTime,
  session,
  onSelect,
  previewSize = 160,
}) {
  const { ref, url } = useThumbnail({
    image,
    session,
    edit: { ...edit, stock: stock?.id ?? null },
    stock: stock?.id ?? null,
    videoTime,
    maxEdge: previewSize,
  });
  return (
    <div ref={ref}>
      <StockButton
        name={name}
        kind={kind}
        normal={!stock}
        url={url}
        selected={active}
        onSelect={onSelect}
      />
    </div>
  );
}
