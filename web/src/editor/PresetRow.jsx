import { useMemo } from "react";
import StockButton from "./StockButton.jsx";
import { useThumbnail } from "./useThumbnail.js";
import { editText } from "../saved-edits.js";
import { pastedEdit } from "../edit-settings.js";

// A preset's thumbnail is the photograph with the preset applied to the settled edit, as a film's
// is with only the film swapped. It reads as chosen while applying it again would change nothing.
export function PresetRow({
  preset,
  stocks,
  current,
  image,
  edit,
  videoTime,
  session,
  onSelect,
  previewSize = 160,
}) {
  const shown = useMemo(() => {
    try {
      return pastedEdit(edit, preset.settings, stocks);
    } catch {
      return null;
    }
  }, [edit, preset, stocks]);
  const active = useMemo(() => {
    try {
      return (
        editText(pastedEdit(current, preset.settings, stocks)) ===
        editText(current)
      );
    } catch {
      return false;
    }
  }, [current, preset, stocks]);
  const { ref, url } = useThumbnail({
    image: shown && image,
    session,
    edit: shown ?? edit,
    stock: shown?.stock ?? null,
    videoTime,
    maxEdge: previewSize,
  });
  const film = preset.settings.sections.includes("filmStock")
    ? preset.settings.edit.stock === null
      ? "No film"
      : stocks.find(({ id }) => id === preset.settings.edit.stock)?.name
    : null;
  return (
    <div ref={ref}>
      <StockButton
        name={preset.name}
        kind={film ?? "Preset"}
        url={url}
        selected={active}
        onSelect={onSelect}
      />
    </div>
  );
}
