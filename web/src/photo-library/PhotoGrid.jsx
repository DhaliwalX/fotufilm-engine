import { useEffect, useLayoutEffect, useRef, useState } from "react";
import PhotoTile from "./PhotoTile.jsx";

const PADDING = 16,
  GAP = 4,
  OVERSCAN = 2;

// Rows of square cells that stretch to fill the width. Only rows near the
// viewport are mounted, so a folder of any size scrolls at the same cost.
export function gridLayout(width, count, tileSize) {
  const inner = Math.max(0, width - PADDING * 2);
  const columns = Math.max(1, Math.floor((inner + GAP) / (tileSize + GAP)));
  const size = Math.max(1, (inner - GAP * (columns - 1)) / columns);
  const rows = Math.ceil(count / columns);
  return {
    columns,
    size,
    row: size + GAP,
    height: rows ? PADDING * 2 + rows * (size + GAP) - GAP : 0,
  };
}

export const tileId = (index) => `library-tile-${index}`;

export default function PhotoGrid({
  photos,
  records,
  tileSize,
  thumbnails,
  selected,
  focusKey,
  onPress,
  onOpen,
  onRate,
  onKeyDown,
  contentKey,
  reflowKey,
  children,
}) {
  const scroller = useRef(null),
    frame = useRef(0),
    anchor = useRef(0);
  const [view, setView] = useState({ width: 0, height: 0, top: 0 });
  const layout = gridLayout(view.width, photos.length, tileSize);
  const [reflowing, setReflowing] = useState(false);
  const firstReflow = useRef(true);
  useEffect(() => {
    if (firstReflow.current) return void (firstReflow.current = false);
    setReflowing(true);
    const timer = setTimeout(() => setReflowing(false), 320);
    return () => clearTimeout(timer);
  }, [reflowKey]);

  useLayoutEffect(() => {
    const element = scroller.current;
    const measure = () =>
      setView((current) => ({
        ...current,
        width: element.clientWidth,
        height: element.clientHeight,
      }));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // Keep the photo at the top left in place when the columns change.
  useLayoutEffect(() => {
    const element = scroller.current;
    const top =
      PADDING + Math.floor(anchor.current / layout.columns) * layout.row;
    if (anchor.current && Math.abs(element.scrollTop - top) > 1)
      element.scrollTop = top;
  }, [layout.columns, layout.row]);

  // Scroll the keyboard focus into view.
  const focusIndex = photos.findIndex((photo) => photo.key === focusKey);
  useEffect(() => {
    if (focusIndex < 0) return;
    const element = scroller.current;
    const top = PADDING + Math.floor(focusIndex / layout.columns) * layout.row;
    if (top < element.scrollTop) element.scrollTop = top - PADDING;
    else if (top + layout.size > element.scrollTop + element.clientHeight)
      element.scrollTop = top + layout.size + PADDING - element.clientHeight;
  }, [focusIndex, layout.columns, layout.row, layout.size]);

  const onScroll = () => {
    cancelAnimationFrame(frame.current);
    frame.current = requestAnimationFrame(() => {
      const top = scroller.current.scrollTop;
      anchor.current =
        Math.max(0, Math.floor((top - PADDING) / layout.row + 0.5)) *
        layout.columns;
      setView((current) => ({ ...current, top }));
    });
  };
  useEffect(() => () => cancelAnimationFrame(frame.current), []);

  const firstRow = Math.max(
    0,
    Math.floor((view.top - PADDING) / layout.row) - OVERSCAN,
  );
  const lastRow = Math.ceil((view.top + view.height) / layout.row) + OVERSCAN;
  const tiles = [];
  for (
    let index = firstRow * layout.columns;
    index < Math.min(photos.length, lastRow * layout.columns);
    index++
  ) {
    const photo = photos[index],
      record = records.get(photo.key);
    tiles.push(
      <PhotoTile
        key={photo.key}
        id={tileId(index)}
        photo={photo}
        x={PADDING + (index % layout.columns) * (layout.size + GAP)}
        y={PADDING + Math.floor(index / layout.columns) * layout.row}
        size={layout.size}
        selected={selected.has(photo.key)}
        focused={photo.key === focusKey}
        rating={record?.rating || 0}
        edited={!!record?.edit}
        thumbnails={thumbnails}
        onPress={onPress}
        onOpen={onOpen}
        onRate={onRate}
      />,
    );
  }

  return (
    <div
      ref={scroller}
      className={`library-grid${reflowing ? " reflowing" : ""}`}
      role="listbox"
      aria-label="Photos"
      aria-multiselectable="true"
      aria-activedescendant={focusIndex >= 0 ? tileId(focusIndex) : undefined}
      tabIndex={0}
      onScroll={onScroll}
      onKeyDown={(event) => {
        event.currentTarget.dataset.keyboard = "";
        onKeyDown(event, layout);
      }}
      onPointerDown={(event) => delete event.currentTarget.dataset.keyboard}
      style={{ "--library-tile": `${layout.size}px` }}
    >
      <div
        key={contentKey}
        className="library-grid-content"
        style={{ height: layout.height }}
      >
        {tiles}
      </div>
      {children}
    </div>
  );
}
