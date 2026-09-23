import { useEffect } from "react";

// Local to the player/viewer. Form fields, Spectrum menus and editor shortcuts retain ownership.
export function usePlayerShortcuts(root, playback, disabled) {
  useEffect(() => {
    const viewer = root.current?.closest(".viewer");
    if (!viewer) return;
    function keydown(event) {
      if (
        disabled ||
        event.repeat ||
        event.metaKey ||
        event.ctrlKey ||
        event.altKey ||
        event.target.closest(
          "input,textarea,select,[role=slider],[role=dialog],[role=menu],[role=combobox],[contenteditable=true]",
        )
      )
        return;
      const key = event.key.toLowerCase();
      if (key === " " && event.target.closest("button")) return;
      if (key === " " || key === "k") playback.transport.current?.toggle();
      else if (key === "arrowleft" || key === "j")
        playback.transport.current?.skip(-5);
      else if (key === "arrowright" || key === "l")
        playback.transport.current?.skip(5);
      else if (key === "m") playback.setMuted(!playback.muted);
      else return;
      event.preventDefault();
      event.stopPropagation();
    }
    viewer.addEventListener("keydown", keydown);
    return () => viewer.removeEventListener("keydown", keydown);
  }, [root, playback.transport, playback.muted, disabled]);
}
