import { useEffect, useState } from "react";
import { motion } from "motion/react";
import { useEditor } from "./EditorContext.jsx";

const EASE = [0.2, 0.8, 0.2, 1];

// Where the viewer will fit the photo: the canvas area less its 24 px margin.
function viewerRect(aspect) {
  const area =
    document.querySelector(".viewer .canvas-area") ||
    document.querySelector(".viewer");
  if (!area) return null;
  const room = area.getBoundingClientRect();
  const fit = Math.min((room.width - 48) / aspect, room.height - 48);
  const width = fit * aspect,
    height = fit;
  return {
    left: room.left + (room.width - width) / 2,
    top: room.top + (room.height - height) / 2,
    width,
    height,
  };
}

// The opened photo's thumbnail flies from its tile to the viewer and stays as a
// placeholder until the developed photo is on screen.
export default function LibraryHandoff() {
  const {
    libraryHandoff: handoff,
    endLibraryHandoff,
    active,
    shownResult,
    visibleError,
  } = useEditor();
  const [target, setTarget] = useState(null),
    [landed, setLanded] = useState(false);
  useEffect(() => {
    setLanded(false);
    setTarget(
      handoff ? viewerRect(handoff.rect.width / handoff.rect.height) : null,
    );
    if (!handoff) return;
    const timeout = setTimeout(endLibraryHandoff, 15000);
    return () => clearTimeout(timeout);
  }, [handoff, endLibraryHandoff]);
  const ready =
    landed &&
    ((active?.libraryKey === handoff?.key && shownResult) || visibleError);
  if (!handoff || !target) return null;
  const { rect } = handoff;
  return (
    <motion.img
      key={`${handoff.key}@${handoff.src}`}
      className="library-handoff"
      src={handoff.src}
      alt=""
      aria-hidden="true"
      style={{ ...target, transformOrigin: "0 0" }}
      initial={{
        x: rect.left - target.left,
        y: rect.top - target.top,
        scaleX: rect.width / target.width,
        scaleY: rect.height / target.height,
        opacity: 1,
      }}
      animate={{ x: 0, y: 0, scaleX: 1, scaleY: 1, opacity: ready ? 0 : 1 }}
      transition={{
        default: { duration: 0.42, ease: EASE },
        opacity: { duration: 0.24, ease: "easeOut" },
      }}
      onAnimationComplete={() =>
        ready ? endLibraryHandoff() : setLanded(true)
      }
    />
  );
}
