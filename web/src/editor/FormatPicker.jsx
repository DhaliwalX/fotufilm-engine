import { useState } from "react";
import { Button } from "@react-spectrum/s2/Button";
import { Switch } from "@react-spectrum/s2/Switch";
import { FILM_FORMATS } from "../generated/controls.js";
import { useEditor } from "./EditorContext.jsx";
import { useThumbnail, useThumbnailSource } from "./useThumbnail.js";

// The film format, chosen by eye as the Mac app's gauge picker offers it: the photograph as each
// format would have given it, from Super 8 to 4x5, whole or as a magnified detail where the
// format tells.
const SHORT_NAMES = {
  super8: "Super 8",
  "16mm": "16 mm",
  super35: "Super 35",
  "35mm": "35 mm",
  120: "120",
  "4x5": "4×5",
};
// A quarter of the frame each way, from the middle.
const DETAIL = [
  [0.375, 0.375],
  [0.625, 0.375],
  [0.625, 0.625],
  [0.375, 0.625],
];

function FormatTile({ format, selected, source, detail, session, disabled, onSelect }) {
  const edit = source.edit && {
    ...source.edit,
    format: format.id,
    ...(detail ? { crop: DETAIL, cropShape: "rectangle" } : {}),
  };
  const { ref, url } = useThumbnail({
    image: source.image,
    session,
    edit,
    stock: edit?.stock,
    videoTime: source.videoTime,
    // The edge caps the whole frame, and the detail is a quarter of it.
    maxEdge: detail ? 168 * 4 : 168,
  });
  return (
    <button
      ref={ref}
      type="button"
      className="format-tile"
      aria-pressed={selected}
      title={format.name}
      disabled={disabled}
      onClick={onSelect}
    >
      <span className="format-tile-image">{url && <img src={url} alt="" />}</span>
      <span className="format-tile-name">{SHORT_NAMES[format.id] ?? format.name}</span>
    </button>
  );
}

export default function FormatPicker({ disabled, onChange }) {
  const { edit, active, videoTime, backend, session, selectedStock } = useEditor();
  const [detail, setDetail] = useState(true);
  const source = useThumbnailSource({ active, edit, videoTime, backend });
  // An unpicked format follows the camera's frame where the file records it, the film's
  // otherwise, as the engine develops it.
  const sensor = active?.image.sensor;
  const selected = edit.format ?? sensor?.gauge ?? selectedStock?.nativeFormat;
  const followed = FILM_FORMATS.find(({ id }) => id === selected);
  return (
    <div className="format-picker">
      <div className="format-grid">
        {FILM_FORMATS.map((format) => (
          <FormatTile
            key={format.id}
            format={format}
            selected={format.id === selected}
            source={source}
            detail={detail}
            session={session}
            disabled={disabled}
            onSelect={() => onChange(format.id)}
          />
        ))}
      </div>
      <Switch isSelected={detail} onChange={setDetail} size="S">
        Magnified Detail
      </Switch>
      {edit.format ? (
        <Button size="S" variant="secondary" isDisabled={disabled} onPress={() => onChange(null)}>
          {sensor ? "Match the Camera" : "Match the Film"}
        </Button>
      ) : sensor ? (
        <p className="medium-detail">
          Following the camera. The camera’s frame size is {sensor.frameSize}.
          Fotufilm uses the closest film format: {followed?.name}.
        </p>
      ) : (
        <p className="medium-detail">Following the film.</p>
      )}
      <p className="medium-detail">
        Smaller film formats are enlarged more, so the same film shows coarser
        grain and softer highlights.
      </p>
    </div>
  );
}
