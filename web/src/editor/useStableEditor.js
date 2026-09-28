import { useMemo, useRef } from "react";
import { usePlaying } from "../video-player/usePlaying.js";

// Fields that change with every frame a movie plays, and with every preview. Components that
// show them read `useEditorFrame()`; the editor context keeps its last value while only these
// change.
export const FRAME_FIELDS = [
  "videoTime",
  "result",
  "shownResult",
  "status",
  "previewKey",
  "detailRequest",
  "interacting",
  "previewInteracting",
  "interactionKey",
  "editInteractionKey",
];
const FRAME = new Set(FRAME_FIELDS);

// Splits the editor model into the value most of the editor reads, kept while nothing it holds
// has changed, and the per-frame fields. Actions become stable forwarders to their newest
// version, so a kept value never calls a stale closure. The playhead stays in the kept value
// while the movie is paused, for the thumbnails that follow it once it settles.
export default function useStableEditor(editor) {
  const playing = usePlaying();
  const latest = useRef(editor);
  latest.current = editor;
  const forwarders = useRef(new Map());
  const kept = useRef(null);
  const next = {};
  for (const key of Object.keys(editor)) {
    const value = editor[key];
    if (typeof value !== "function") {
      next[key] = value;
      continue;
    }
    let forward = forwarders.current.get(key);
    if (!forward) {
      forward = (...args) => latest.current[key](...args);
      forwarders.current.set(key, forward);
    }
    next[key] = forward;
  }
  const previous = kept.current;
  const ignored = (key) => FRAME.has(key) && !(key === "videoTime" && !playing);
  const same =
    previous &&
    Object.keys(previous).length === Object.keys(next).length &&
    Object.keys(next).every(
      (key) =>
        key in previous &&
        (ignored(key) || Object.is(previous[key], next[key])),
    );
  if (!same) kept.current = next;
  const frameValues = FRAME_FIELDS.map((key) => editor[key]);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const frame = useMemo(
    () =>
      Object.fromEntries(
        FRAME_FIELDS.map((key, index) => [key, frameValues[index]]),
      ),
    frameValues,
  );
  return { editor: kept.current, frame };
}
