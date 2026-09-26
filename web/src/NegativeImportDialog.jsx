import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Switch } from "@react-spectrum/s2/Switch";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { memo, useCallback, useEffect, useRef, useState } from "react";
import { RAW_EXTENSIONS } from "./media-types.js";
import { colorContext } from "./canvas-color.js";
import { useBackend } from "./backend/BackendContext.jsx";
import { Adjustment } from "./Adjustment.jsx";
import {
  NEGATIVE_ADJUSTMENTS,
  NEGATIVE_CONTRAST,
  defaultNegativeSettings,
  isColourAdjustment,
} from "./negative-live-preview.js";
import { useLivePositive } from "./useNegativePreview.js";
import "./negative-import.css";

// The dialog owns every provisional image, URL and conversion. Only a completed
// positive is handed to the library; closing it never replaces the current photo.
export default function NegativeImportDialog({ onClose, model }) {
  const {
    file,
    setFile,
    decoded,
    plan,
    negative,
    setNegative,
    status,
    error,
    busy,
    importPositive,
  } = model;
  const picker = useRef(null);
  const [settings, setSettings] = useState(defaultNegativeSettings);
  // Closing the dialog clears the file; the next negative starts from the defaults.
  useEffect(() => {
    if (!file) setSettings(defaultNegativeSettings());
  }, [file]);
  const positive = useLivePositive(model, settings);
  // One stable handler for every slider lets an unchanged slider skip re-rendering.
  const setValue = useCallback(
    (key, value) =>
      setSettings((current) =>
        key === NEGATIVE_CONTRAST.key
          ? { ...current, contrast: value }
          : {
              ...current,
              adjustments: { ...current.adjustments, [key]: value },
            },
      ),
    [],
  );
  return (
    <Dialog
      aria-label="Import Scanned Negative"
      UNSAFE_className="negative-import-dialog"
      isDismissible
      size={"L"}
    >
      <Heading>{"Import Scanned Negative"}</Heading>
      <Content>
        <div className="negative-import">
          <div className="negative-import-controls">
            <ActionButton
              onPress={() => picker.current?.click()}
              isDisabled={busy}
              size={"S"}
            >
              Choose Negative…
            </ActionButton>
            <Switch
              isSelected={settings.monochrome}
              isDisabled={busy}
              onChange={(monochrome) =>
                setSettings((current) => ({ ...current, monochrome }))
              }
              size={"S"}
            >
              {" "}
              Black &amp; white
            </Switch>
            <ToggleButton
              isDisabled={!positive || busy}
              onPress={() => setNegative((v) => !v)}
              size={"S"}
              isSelected={negative}
            >
              {negative ? "Show Positive" : "Show Negative"}
            </ToggleButton>
          </div>
          <input
            ref={picker}
            type="file"
            accept={[
              ".tif",
              ".tiff",
              ".png",
              ".jpg",
              ".jpeg",
              ...RAW_EXTENSIONS.map((ext) => `.${ext}`),
            ].join(",")}
            hidden
            onChange={(e) => {
              setFile(e.target.files[0] || null);
              e.target.value = "";
            }}
          />
          <div className="negative-import-preview" aria-busy={!!file && !plan}>
            {negative && decoded?.src ? (
              <img key="negative" src={decoded.src} alt="Original negative" />
            ) : !negative && positive ? (
              <PositiveCanvas frame={positive} />
            ) : (
              <span>
                {file
                  ? "Preparing preview…"
                  : "Choose a negative to preview its conversion"}
              </span>
            )}
          </div>
          <NegativeAdjustments
            settings={settings}
            disabled={!plan || busy}
            onChange={setValue}
          />
          <p className="negative-import-status" role="status">
            {status}
          </p>
          {error && (
            <p role="alert" className="negative-import-error">
              {error}
            </p>
          )}
          <div className="negative-import-actions">
            <ActionButton onPress={onClose} size={"S"}>
              Cancel
            </ActionButton>
            <ActionButton
              onPress={() => importPositive(settings)}
              isDisabled={!plan || busy}
              size={"S"}
            >
              Import Positive
            </ActionButton>
          </div>
        </div>
      </Content>
    </Dialog>
  );
}

// Every change re-renders the positive while the slider moves.
function NegativeAdjustments({ settings, disabled, onChange }) {
  const { negativeContrast } = useBackend();
  return (
    <div className="negative-import-adjustments">
      {negativeContrast && (
        <NegativeSlider
          slider={NEGATIVE_CONTRAST}
          value={settings.contrast}
          disabled={disabled}
          onChange={onChange}
        />
      )}
      {NEGATIVE_ADJUSTMENTS.map((slider) => (
        <NegativeSlider
          key={slider.key}
          slider={slider}
          value={settings.adjustments[slider.key]}
          disabled={
            disabled || (settings.monochrome && isColourAdjustment(slider))
          }
          onChange={onChange}
        />
      ))}
    </div>
  );
}

// Re-renders only when its own value or availability changes.
const NegativeSlider = memo(function NegativeSlider({
  slider,
  value,
  disabled,
  onChange,
}) {
  return (
    <Adjustment
      slider={slider}
      value={value}
      disabled={disabled}
      onChange={(next) => onChange(slider.key, next)}
    />
  );
});

// Frames are drawn as they arrive: decoding off the main thread and drawing
// directly keeps a moving slider in step with the positive.
function PositiveCanvas({ frame }) {
  const canvas = useRef(null);
  useEffect(() => {
    let current = true;
    createImageBitmap(frame.blob).then((bitmap) => {
      const target = canvas.current;
      if (current && target) {
        target.width = bitmap.width;
        target.height = bitmap.height;
        colorContext(target, frame.colorSpace).drawImage(bitmap, 0, 0);
      }
      bitmap.close();
    });
    return () => {
      current = false;
    };
  }, [frame]);
  return (
    <canvas
      ref={canvas}
      role="img"
      aria-label="Converted positive preview"
      className="negative-import-positive"
    />
  );
}
