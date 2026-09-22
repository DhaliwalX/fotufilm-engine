import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { useRef, useState, useEffect } from "react";
import { defaultEdit } from "../editor-state.js";
import { Icon } from "../icons.jsx";
export function StockRow({ stock, active, image, session, onSelect }) {
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
              maxEdge: 160,
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
  }, [image, session, stock.id]);
  return (
    <div ref={ref}>
      <ToggleButton
        isQuiet
        UNSAFE_className={`stock-row ${active ? "selected" : ""}`}
        onPress={onSelect}
        title={stock.name}
        size={"S"}
        isSelected={active}
      >
        <span className="stock-thumb">
          {url ? <img src={url} alt="" /> : <Icon name="film" />}
        </span>
        <span className="stock-copy">
          <span>{stock.name}</span>
          <small>{stock.kind || "Film"}</small>
        </span>
        {active && <Icon name="check" />}
      </ToggleButton>
    </div>
  );
}
