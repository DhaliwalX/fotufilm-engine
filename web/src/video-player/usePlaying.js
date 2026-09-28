import { useEffect, useState } from "react";
import { PLAYBACK_STATE } from "./usePlayerShortcuts.js";

/** Whether the open movie is playing, as its transport announces it. */
export function usePlaying() {
  const [playing, setPlaying] = useState(false);
  useEffect(() => {
    const changed = (event) => setPlaying(event.detail?.playing === true);
    window.addEventListener(PLAYBACK_STATE, changed);
    return () => window.removeEventListener(PLAYBACK_STATE, changed);
  }, []);
  return playing;
}
