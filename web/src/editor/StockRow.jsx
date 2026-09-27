import StockButton from "./StockButton.jsx";
import { useRef, useState, useEffect } from "react";
import { defaultEdit } from "../editor-state.js";

// A film's thumbnail is the photograph as that film would develop it under the edit it has now,
// as the Mac app's film column shows it: `edit` (already settled by the caller) with only the
// film swapped. The last thumbnail stays up until the next one arrives.
export function StockRow({
  stock,
  active,
  image,
  edit,
  videoTime,
  session,
  onSelect,
  previewSize = 160,
}) {
  const ref = useRef(null),
    [thumbnail, setThumbnail] = useState(null);
  const shown = edit ? JSON.stringify({ ...edit, stock: stock.id }) : null;
  useEffect(() => {
    if (!image || !session) return;
    let cancelled = false,
      timer;
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      // Wait until the main preview has been queued before thumbnail work.
      timer = setTimeout(
        () =>
          session
            .render({
              image,
              stock: stock.id,
              edit: shown ? JSON.parse(shown) : defaultEdit(stock.id),
              videoTime,
              maxEdge: previewSize,
              background: true,
              stale: () => cancelled,
            })
            .then((result) => {
              if (!result || cancelled) return;
              const url = URL.createObjectURL(result.blob);
              setThumbnail((previous) => {
                if (previous) URL.revokeObjectURL(previous.url);
                return { image, url };
              });
            })
            .catch(() => {}),
        400,
      );
    });
    observer.observe(ref.current);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      observer.disconnect();
    };
  }, [image, session, stock.id, previewSize, shown, videoTime]);
  // Another photograph's thumbnail never stands in for this one's.
  useEffect(
    () => () =>
      setThumbnail((previous) => {
        if (previous) URL.revokeObjectURL(previous.url);
        return null;
      }),
    [image],
  );
  return (
    <div ref={ref}>
      <StockButton
        name={stock.name}
        kind={stock.kind || "Film"}
        url={thumbnail && thumbnail.image === image ? thumbnail.url : null}
        selected={active}
        onSelect={onSelect}
      />
    </div>
  );
}
