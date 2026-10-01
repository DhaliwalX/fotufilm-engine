import { useSyncExternalStore } from "react";
import { MAX_ZOOM } from "./photo-navigation.js";

const STEP = 0.25;

// The photograph's view belongs to the canvas, which moves it every frame a gesture moves. The rest
// of the editor holds this handle: the toolbar, keys and menus step the zoom through it and read
// where the view stands with `usePhotoView`, rendering only when what they read changes.
export function createPhotoView() {
  let state = { zoom: 1, readout: 100 };
  let canvas = null;
  const listeners = new Set();
  // `zoom` is a number or a function of the current zoom.
  const zoomTo = (zoom) => canvas?.(zoom);
  return {
    get: () => state,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    // The canvas's side: it publishes each view it shows and takes the steps while it is mounted.
    publish(next) {
      if (next.zoom === state.zoom && next.readout === state.readout) return;
      state = next;
      for (const listener of listeners) listener();
    },
    attach(handler) {
      canvas = handler;
      return () => {
        if (canvas === handler) canvas = null;
      };
    },
    zoomIn: () => zoomTo((zoom) => Math.min(MAX_ZOOM, zoom + STEP)),
    zoomOut: () => zoomTo((zoom) => Math.max(1, zoom - STEP)),
    fit: () => zoomTo(1),
  };
}

// Which zoom steps apply: "fit", "zoomed" or "max".
export const zoomReach = ({ zoom }) =>
  zoom <= 1 ? "fit" : zoom >= MAX_ZOOM ? "max" : "zoomed";

const whole = (state) => state;
// `select` must answer a value that stays the same while what it reads does (a string, a number).
export function usePhotoView(view, select = whole) {
  return useSyncExternalStore(view.subscribe, () => select(view.get()));
}
