import { useEffect, useRef } from "react";
import {
  anchoredPhotoZoom,
  constrainPhotoOffset,
  pinchGeometry,
} from "./photo-navigation.js";

export function usePhotoNavigation(options) {
  const live = useRef(options);
  live.current = options;
  const pointers = useRef(new Map());
  const gesture = useRef(null);
  const hold = useRef(null);
  const clearHold = () => {
    clearTimeout(hold.current);
    hold.current = null;
  };
  const apply = (view) => {
    Object.assign(live.current, view);
    live.current.setZoom(view.zoom);
    live.current.setOffset(view.offset);
  };
  const point = (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    return [
      event.clientX - rect.left - rect.width / 2,
      event.clientY - rect.top - rect.height / 2,
    ];
  };
  const rebase = () => {
    const { zoom, offset } = live.current;
    const points = [...pointers.current.values()];
    gesture.current =
      points.length > 1
        ? { zoom, offset, ...pinchGeometry(points) }
        : points.length
          ? { zoom, offset, anchor: points[0] }
          : null;
  };
  const reset = () => {
    clearHold();
    pointers.current.clear();
    gesture.current = null;
    live.current.onInteraction?.(false);
    live.current.setCompare(false);
  };
  useEffect(() => {
    reset();
    return reset;
  }, [options.sourceKey, options.cropMode, options.sampling]);
  useEffect(() => {
    const surface = options.container.current;
    const wheel = (event) => {
      const current = live.current;
      if (
        current.cropMode ||
        current.sampling ||
        event.target.closest(".histogram")
      )
        return;
      event.preventDefault();
      const rect = surface.getBoundingClientRect();
      const anchor = [
        event.clientX - rect.left - rect.width / 2,
        event.clientY - rect.top - rect.height / 2,
      ];
      apply(
        anchoredPhotoZoom({
          ...current,
          anchor,
          scale: event.deltaY > 0 ? 0.9 : 1.1,
        }),
      );
    };
    surface.addEventListener("wheel", wheel, { passive: false });
    window.addEventListener("blur", reset);
    return () => {
      surface.removeEventListener("wheel", wheel);
      window.removeEventListener("blur", reset);
    };
  }, [options.container]);

  return {
    onPointerDown(event) {
      const current = live.current;
      if (
        event.button !== 0 ||
        current.cropMode ||
        event.target.closest(".histogram")
      )
        return;
      if (current.sampling) {
        const bounds = event.target
          .closest(".photo-plane")
          ?.getBoundingClientRect();
        if (bounds)
          current.onSample?.([
            (event.clientX - bounds.left) / bounds.width,
            (event.clientY - bounds.top) / bounds.height,
          ]);
        return;
      }
      event.currentTarget.setPointerCapture(event.pointerId);
      pointers.current.set(event.pointerId, point(event));
      clearHold();
      rebase();
      if (pointers.current.size > 1 || current.zoom > 1) {
        current.setCompare(false);
        current.onInteraction?.(true);
      } else if (event.pointerType === "touch") {
        hold.current = setTimeout(() => live.current.setCompare(true), 180);
      } else current.setCompare(true);
    },
    onPointerMove(event) {
      if (!pointers.current.has(event.pointerId)) return;
      const position = point(event);
      pointers.current.set(event.pointerId, position);
      const current = live.current,
        start = gesture.current;
      if (!start) return;
      if (pointers.current.size > 1) {
        clearHold();
        const pinch = pinchGeometry([...pointers.current.values()]);
        apply(
          anchoredPhotoZoom({
            ...current,
            ...start,
            nextAnchor: pinch.anchor,
            scale: pinch.distance / start.distance,
          }),
        );
      } else if (current.zoom > 1) {
        clearHold();
        apply({
          zoom: current.zoom,
          offset: constrainPhotoOffset(
            position.map(
              (value, axis) => start.offset[axis] + value - start.anchor[axis],
            ),
            current.zoom,
            current.display,
            current.room,
          ),
        });
      } else if (
        Math.hypot(
          ...position.map((value, axis) => value - start.anchor[axis]),
        ) > 6
      ) {
        clearHold();
        current.setCompare(false);
      }
    },
    onPointerUp(event) {
      if (!pointers.current.delete(event.pointerId)) return;
      clearHold();
      live.current.setCompare(false);
      if (!pointers.current.size) reset();
      else rebase();
    },
    onPointerCancel: reset,
    onLostPointerCapture(event) {
      if (pointers.current.has(event.pointerId)) reset();
    },
  };
}
