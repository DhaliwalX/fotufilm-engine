import StockButton from "./StockButton.jsx";
import { useRef, useState, useEffect } from "react";
import { defaultEdit } from "../editor-state.js";
export function StockRow({
  stock,
  active,
  image,
  session,
  onSelect,
  previewSize = 160,
}) {
  const ref = useRef(null),
    [url, setUrl] = useState(null);
  useEffect(() => {
    if (!image || !session) return;
    let cancelled = false,
      objectUrl;
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
              edit: defaultEdit(stock.id),
              maxEdge: previewSize,
              background: true,
              stale: () => cancelled,
            })
            .then((result) => {
              if (!result || cancelled) return;
              objectUrl = URL.createObjectURL(result.blob);
              setUrl(objectUrl);
            })
            .catch(() => {}),
        400,
      );
    });
    let timer;
    observer.observe(ref.current);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      observer.disconnect();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      setUrl(null);
    };
  }, [image, session, stock.id, previewSize]);
  return (
    <div ref={ref}>
      <StockButton
        name={stock.name}
        kind={stock.kind || "Film"}
        url={url}
        selected={active}
        onSelect={onSelect}
      />
    </div>
  );
}
