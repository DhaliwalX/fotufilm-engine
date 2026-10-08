import { useCallback, useEffect, useRef, useState } from "react";

// The film list and the inspector either side of the picture, each as wide as it was left
// (PanelResizer). The defaults are the SessionEditor's own, 236 and 330 pixels.
export const PANEL_WIDTHS = {
  film: { initial: 236, min: 180, max: 480 },
  inspector: { initial: 330, min: 280, max: 600 },
};
// The picture between them never narrows past this (base.css).
export const PICTURE_MIN = 420;
const STORAGE_KEY = "fotufilm.panelWidths";

// `width` for `side`, inside its own bounds and leaving the picture its room beside `other`, the
// other panel's width, in a window `windowWidth` across. A panel keeps its least width even in a
// window too narrow for all three.
export function clampedWidth(side, width, other, windowWidth) {
  const { min, max } = PANEL_WIDTHS[side];
  const room = Number.isFinite(windowWidth)
    ? windowWidth - other - PICTURE_MIN
    : max;
  return Math.round(
    Math.max(min, Math.min(max, room, Number.isFinite(width) ? width : min)),
  );
}

// The widths shown for the widths asked for, in a window `windowWidth` across: a narrow window
// takes room back for the picture from the inspector first, then the film list.
export function shownWidths(preferred, windowWidth) {
  const inspector = clampedWidth(
    "inspector",
    preferred.inspector,
    preferred.film,
    windowWidth,
  );
  const film = clampedWidth("film", preferred.film, inspector, windowWidth);
  return { film, inspector };
}

// The widths kept from the last visit, each inside its bounds; the defaults otherwise.
export function keptWidths(text) {
  let kept = null;
  try {
    kept = JSON.parse(text ?? "null");
  } catch {
    kept = null;
  }
  return Object.fromEntries(
    Object.entries(PANEL_WIDTHS).map(([side, { initial, min, max }]) => {
      const width = kept?.[side];
      return [
        side,
        Number.isFinite(width) ? Math.min(max, Math.max(min, width)) : initial,
      ];
    }),
  );
}

const readKept = () => {
  try {
    return keptWidths(localStorage.getItem(STORAGE_KEY));
  } catch {
    return keptWidths(null);
  }
};

export default function usePanelWidths() {
  // The widths asked for, which a window too narrow for them only hides until it widens again.
  const [preferred, setPreferred] = useState(readKept);
  const [windowWidth, setWindowWidth] = useState(() => window.innerWidth);
  useEffect(() => {
    const resized = () => setWindowWidth(window.innerWidth);
    window.addEventListener("resize", resized);
    return () => window.removeEventListener("resize", resized);
  }, []);
  const widths = shownWidths(preferred, windowWidth);
  const latest = useRef({ widths, preferred });
  latest.current = { widths, preferred };

  // Sets `side`'s width as far as the window allows; `keep` remembers both for the next visit,
  // as a drag's end does.
  const setWidth = useCallback((side, width, keep = false) => {
    const { widths: shown, preferred: asked } = latest.current;
    const other = side === "film" ? shown.inspector : shown.film;
    // The other panel keeps the width asked of it, even where the window shows it narrower.
    const next = {
      ...asked,
      [side]: clampedWidth(side, width, other, window.innerWidth),
    };
    setPreferred(next);
    if (keep)
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      } catch {
        // A browser that keeps nothing still resizes for this visit.
      }
  }, []);
  return {
    panelWidths: widths,
    setPanelWidth: setWidth,
    panelWidthStyle: {
      "--film-width": `${widths.film}px`,
      "--inspector-width": `${widths.inspector}px`,
    },
  };
}
