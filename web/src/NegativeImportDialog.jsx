import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Switch } from "@react-spectrum/s2/Switch";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useEffect, useRef, useState } from "react";
import { importPhoto } from "./photo-import.js";
import { isRawFile, importRaw, RAW_EXTENSIONS } from "./raw-import.js";
import { analyseNegative, convertNegative } from "./negative-conversion.js";
import { attachLinearPreview } from "./linear-preview.js";
import "./negative-import.css";

// The dialog owns every provisional image, URL and conversion. Only a completed
// positive is handed to the library; closing it never replaces the current photo.
export default function NegativeImportDialog({ onClose, onImport }) {
  const [file, setFile] = useState(null),
    [decoded, setDecoded] = useState(null);
  const [positive, setPositive] = useState(null),
    [plan, setPlan] = useState(null);
  const [monochrome, setMonochrome] = useState(false),
    [negative, setNegative] = useState(false);
  const [status, setStatus] = useState(
    "Choose an unadjusted image or camera RAW negative.",
  );
  const [error, setError] = useState(null),
    [busy, setBusy] = useState(false);
  const finalController = useRef(null),
    picker = useRef(null);
  useEffect(() => () => finalController.current?.abort(), []);
  useEffect(() => {
    if (!file) return;
    const controller = new AbortController();
    let url;
    setDecoded(null);
    setPositive(null);
    setPlan(null);
    setError(null);
    setStatus("Reading negative…");
    const run = async () => {
      const result = await (isRawFile(file) ? importRaw : importPhoto)(file, {
        signal: controller.signal,
        onProgress: setStatus,
        negative: true,
      });
      url = result.url;
      if (controller.signal.aborted) {
        URL.revokeObjectURL(url);
        return;
      }
      setDecoded(result.image);
    };
    run().catch((error) => {
      if (!controller.signal.aborted) {
        setError(error.message);
        setStatus("");
      }
    });
    return () => {
      controller.abort();
      if (url) URL.revokeObjectURL(url);
    };
  }, [file]);
  useEffect(() => {
    if (!decoded) return;
    const controller = new AbortController();
    let url;
    setPlan(null);
    setPositive(null);
    setError(null);
    setStatus("Analysing negative…");
    const run = async () => {
      const analysis = await analyseNegative(decoded, monochrome);
      if (controller.signal.aborted) return;
      const result = await convertNegative(decoded, analysis, {
        signal: controller.signal,
        maxEdge: 1200,
        onProgress: () => setStatus("Rendering positive preview…"),
      });
      const preview = await attachLinearPreview(result.image, {
        signal: controller.signal,
      });
      url = preview.url;
      if (controller.signal.aborted) {
        URL.revokeObjectURL(url);
        return;
      }
      setPlan(analysis);
      setPositive(preview.image);
      setNegative(false);
      setStatus(
        analysis.weak
          ? "Limited tonal range: review the preview before importing."
          : "Positive ready. You can adjust crop, colour and tone after importing.",
      );
    };
    run().catch((error) => {
      if (!controller.signal.aborted) {
        setError(error.message);
        setStatus("");
      }
    });
    return () => {
      controller.abort();
      if (url) URL.revokeObjectURL(url);
    };
  }, [decoded, monochrome]);
  async function importPositive() {
    if (!plan || busy) return;
    const controller = new AbortController();
    finalController.current = controller;
    setBusy(true);
    setError(null);
    try {
      const result = await convertNegative(decoded, plan, {
        signal: controller.signal,
        onProgress: ({ progress }) =>
          setStatus(
            `Converting full resolution… ${Math.round(progress * 100)}%`,
          ),
      });
      const completed = await attachLinearPreview(result.image, {
        signal: controller.signal,
      });
      if (controller.signal.aborted) {
        URL.revokeObjectURL(completed.url);
        return;
      }
      onImport({
        ...completed,
        name: `${file.name} — Positive`,
        id: crypto.randomUUID(),
      });
    } catch (error) {
      if (!controller.signal.aborted) {
        setError(error.message);
        setBusy(false);
        setStatus("");
      }
    }
  }
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
