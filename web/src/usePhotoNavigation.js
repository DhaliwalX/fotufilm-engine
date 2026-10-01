import { useEffect, useRef } from "react";
import {
  anchoredPhotoZoom,
  constrainPhotoOffset,
  pinchGeometry,
  scrolledPhotoView,
  wheelDistance,
  wheelZoomScale,
} from "./photo-navigation.js";

// Wheel, drag and pinch over the photograph, as a native image viewer takes them: a scroll moves
// a magnified photograph, a pinch (or a scroll with Command, Option or Control) zooms about the
// pointer, and a double click or a two-finger double tap zooms in and back (`toggle`). `view` is
// a ref to the newest {zoom, offset}, which may be ahead of the last render; every change goes to
// `show`, which renders it once a frame.
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
  const apply = (view) => live.current.show(view);
  const viewed = () => live.current.view.current;
  const point = (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    return [
      event.clientX - rect.left - rect.width / 2,
      event.clientY - rect.top - rect.height / 2,
    ];
  };
  const rebase = () => {
    const { zoom, offset } = viewed();
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
    live.current.setCompare(false);
  };
  useEffect(() => {
    reset();
    return reset;
  }, [options.sourceKey, options.cropMode, options.sampling]);
  useEffect(() => {
    const surface = options.container.current;
    // Where on the photograph a point of the page is, from the viewer's centre; null where the
    // photograph is not what is under it (another panel, the histogram over it).
    const anchorAt = (x, y) => {
      const current = live.current;
      if (current.cropMode || current.sampling) return null;
      const under = document.elementFromPoint(x, y);
      if (!under || !surface.contains(under) || under.closest(".histogram"))
        return null;
      const rect = surface.getBoundingClientRect();
      return [x - rect.left - rect.width / 2, y - rect.top - rect.height / 2];
    };
    const zoom = (anchor, scale) => {
      const { display, room } = live.current;
      apply(anchoredPhotoZoom({ ...viewed(), display, room, anchor, scale }));
    };
    const wheel = (event) => {
      const anchor = anchorAt(event.clientX, event.clientY);
      if (!anchor) return;
      event.preventDefault();
      const height = surface.clientHeight;
      if (event.ctrlKey || event.metaKey || event.altKey)
        zoom(anchor, wheelZoomScale(event, height));
      else if (viewed().zoom > 1) {
        const { display, room } = live.current;
        apply(
          scrolledPhotoView(
            { ...viewed(), display, room },
            wheelDistance(event, height),
          ),
        );
      }
    };
    // The desktop host's exact pinch and two-finger double tap (cef/src/platform/mac).
    const magnify = ({ detail }) => {
      const anchor = anchorAt(detail.x, detail.y);
      if (anchor) zoom(anchor, detail.scale);
    };
    const smartMagnify = ({ detail }) => {
      const anchor = anchorAt(detail.x, detail.y);
      if (anchor) live.current.toggle(anchor);
    };
    surface.addEventListener("wheel", wheel, { passive: false });
    window.addEventListener("fotufilm-native-magnify", magnify);
    window.addEventListener("fotufilm-native-smart-magnify", smartMagnify);
    window.addEventListener("blur", reset);
    return () => {
      surface.removeEventListener("wheel", wheel);
      window.removeEventListener("fotufilm-native-magnify", magnify);
      window.removeEventListener("fotufilm-native-smart-magnify", smartMagnify);
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
      if (pointers.current.size > 1 || viewed().zoom > 1) {
        current.setCompare(false);
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
            display: current.display,
            room: current.room,
            ...start,
            nextAnchor: pinch.anchor,
            scale: pinch.distance / start.distance,
          }),
        );
      } else if (viewed().zoom > 1) {
        const { zoom } = viewed();
        clearHold();
        apply({
          zoom,
          offset: constrainPhotoOffset(
            position.map(
              (value, axis) => start.offset[axis] + value - start.anchor[axis],
            ),
            zoom,
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
