import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Switch } from "@react-spectrum/s2/Switch";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useRef } from "react";
import { RAW_EXTENSIONS } from "./media-types.js";
import "./negative-import.css";

// The dialog owns every provisional image, URL and conversion. Only a completed
// positive is handed to the library; closing it never replaces the current photo.
export default function NegativeImportDialog({ onClose, model }) {
  const {
    file,
    setFile,
    decoded,
    positive,
    plan,
    monochrome,
    setMonochrome,
    negative,
    setNegative,
    status,
    error,
    busy,
    importPositive,
  } = model;
  const picker = useRef(null);
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
              isSelected={monochrome}
              isDisabled={busy}
              onChange={(e) => setMonochrome(e)}
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
            {(negative ? decoded : positive)?.src ? (
              <img
                key={negative ? "negative" : positive.src}
                src={(negative ? decoded : positive).src}
                alt={
                  negative ? "Original negative" : "Converted positive preview"
                }
              />
            ) : (
              <span>
                {file
                  ? "Preparing preview…"
                  : "Choose a negative to preview its conversion"}
              </span>
            )}
          </div>
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
              onPress={importPositive}
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
