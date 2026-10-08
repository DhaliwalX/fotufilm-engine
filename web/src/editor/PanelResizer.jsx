import { useRef } from "react";
import { PANEL_WIDTHS } from "./usePanelWidths.js";

const LABEL = { film: "Resize film list", inspector: "Resize darkroom panel" };
const STEP = 16;

// The edge between the picture and a side panel, dragged to widen or narrow the panel: the film
// list's right edge, the inspector's left. Arrow keys move it too, Shift for larger steps, and a
// double-click or Return puts it back. While it moves the grid follows the pointer without easing.
export default function PanelResizer({ side, width, onResize }) {
  const drag = useRef(null);
  const { initial, min, max } = PANEL_WIDTHS[side];
  // The film list widens to the right, the inspector to the left.
  const direction = side === "film" ? 1 : -1;
  const editor = (element) => element.closest(".editor");

  function end(event, keep) {
    if (!drag.current) return;
    const { startX, startWidth } = drag.current;
    drag.current = null;
    editor(event.currentTarget)?.classList.remove("panel-resizing");
    if (keep)
      onResize(side, startWidth + direction * (event.clientX - startX), true);
  }
  return (
    <div
      className={`panel-resizer panel-resizer-${side}`}
      role="separator"
      aria-orientation="vertical"
      aria-label={LABEL[side]}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={width}
      tabIndex={0}
      onPointerDown={(event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.currentTarget.setPointerCapture(event.pointerId);
        drag.current = { startX: event.clientX, startWidth: width };
        editor(event.currentTarget)?.classList.add("panel-resizing");
      }}
      onPointerMove={(event) => {
        if (!drag.current) return;
        const { startX, startWidth } = drag.current;
        onResize(side, startWidth + direction * (event.clientX - startX));
      }}
      onPointerUp={(event) => end(event, true)}
      onPointerCancel={(event) => end(event, false)}
      onLostPointerCapture={(event) => end(event, false)}
      onDoubleClick={() => onResize(side, initial, true)}
      onKeyDown={(event) => {
        const step = event.shiftKey ? STEP * 4 : STEP;
        let next = null;
        if (event.key === "ArrowRight") next = width + direction * step;
        else if (event.key === "ArrowLeft") next = width - direction * step;
        else if (event.key === "Home") next = min;
        else if (event.key === "End") next = max;
        else if (event.key === "Enter") next = initial;
        if (next === null) return;
        event.preventDefault();
        onResize(side, next, true);
      }}
    />
  );
}
