import { useLayoutEffect, useRef, useState } from "react";
import { clamp } from "./color-controls.js";
export function constrainPanel(rect, room) {
  const padding = Math.min(12, room.width / 8, room.height / 8);
  const maxWidth = Math.max(1, room.width - padding * 2),
    maxHeight = Math.max(1, room.height - padding * 2);
  const width = clamp(rect.width, Math.min(128, maxWidth), maxWidth),
    height = clamp(rect.height, Math.min(72, maxHeight), maxHeight);
  return {
    width,
    height,
    x: clamp(rect.x, padding, Math.max(padding, room.width - width - padding)),
    y: clamp(
      rect.y,
      padding,
      Math.max(padding, room.height - height - padding),
    ),
  };
}
export function useFloatingPanel(container, open) {
  const [rect, setRect] = useState({ x: 12, y: 12, width: 380, height: 260 });
  const room = useRef({ width: 1000, height: 1000 }),
    gesture = useRef(null);
  useLayoutEffect(() => {
    if (!open || !container.current) return;
    const update = () => {
      room.current = {
        width: container.current.clientWidth,
        height: container.current.clientHeight,
      };
      setRect((r) => constrainPanel(r, room.current));
    };
    update();
    const observer = new ResizeObserver(update);
    observer.observe(container.current);
    return () => observer.disconnect();
  }, [container, open]);
  const handlers = (kind) => ({
    onPointerDown(e) {
      if (
        e.button !== 0 ||
        (kind === "move" &&
          e.target.closest("button,select,input,label") &&
          !e.target.closest(".histogram-drag"))
      )
        return;
      e.stopPropagation();
      e.preventDefault();
      e.currentTarget.setPointerCapture(e.pointerId);
      gesture.current = { kind, x: e.clientX, y: e.clientY, rect };
    },
    onPointerMove(e) {
      const g = gesture.current;
      if (!g || g.kind !== kind) return;
      e.stopPropagation();
      const dx = e.clientX - g.x,
        dy = e.clientY - g.y;
      const next =
        kind === "move"
          ? { ...g.rect, x: g.rect.x + dx, y: g.rect.y + dy }
          : {
              ...g.rect,
              width: Math.min(
                g.rect.width + dx,
                room.current.width - g.rect.x - 12,
              ),
              height: Math.min(
                g.rect.height + dy,
                room.current.height - g.rect.y - 12,
              ),
            };
      setRect(constrainPanel(next, room.current));
    },
    onPointerUp(e) {
      if (gesture.current) {
        e.stopPropagation();
        gesture.current = null;
      }
    },
    onPointerCancel() {
      gesture.current = null;
    },
    onLostPointerCapture() {
      gesture.current = null;
    },
    onKeyDown(e) {
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key))
        return;
      if (e.target !== e.currentTarget) return;
      e.preventDefault();
      e.stopPropagation();
      const step = e.shiftKey ? 32 : 8;
      const dx =
        e.key === "ArrowRight" ? step : e.key === "ArrowLeft" ? -step : 0;
      const dy = e.key === "ArrowDown" ? step : e.key === "ArrowUp" ? -step : 0;
      setRect((r) =>
        constrainPanel(
          kind === "move"
            ? { ...r, x: r.x + dx, y: r.y + dy }
            : {
                ...r,
                width: Math.min(r.width + dx, room.current.width - r.x - 12),
                height: Math.min(r.height + dy, room.current.height - r.y - 12),
              },
          room.current,
        ),
      );
    },
  });
  return { rect, move: handlers("move"), resize: handlers("resize") };
}
