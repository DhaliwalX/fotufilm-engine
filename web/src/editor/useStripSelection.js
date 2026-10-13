import { useEffect, useState } from "react";
import {
  allStrip,
  chosenFiles,
  pressedStrip,
  stripStart,
} from "./strip-selection.js";

// Which photos of the strip are chosen (strip-selection.js). Showing another photo by any other
// way than a modified click — opening, closing, the library — chooses it alone.
export default function useStripSelection({
  files,
  activeId,
  selectFile,
  exporting,
}) {
  const [selection, setSelection] = useState(() => stripStart(activeId));
  useEffect(() => {
    setSelection((current) =>
      activeId && current.selected.has(activeId)
        ? current
        : stripStart(activeId),
    );
  }, [activeId]);

  function pressPhoto(
    file,
    { shiftKey = false, metaKey = false, ctrlKey = false } = {},
  ) {
    if (exporting) return;
    const range = shiftKey,
      toggle = metaKey || ctrlKey;
    setSelection((current) =>
      pressedStrip(files, activeId, current, file.id, { range, toggle }),
    );
    if (!range && !toggle) selectFile(file);
  }

  return {
    selectedFiles: chosenFiles(files, activeId, selection),
    pressPhoto,
    selectAllPhotos: () => setSelection(allStrip(files, activeId)),
    clearPhotoSelection: () => setSelection(stripStart(activeId)),
  };
}
