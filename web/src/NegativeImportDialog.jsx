import { useEffect, useRef, useState } from "react";
import { Modal } from "./EditorControls.jsx";
import { importPhoto } from "./photo-import.js";
import { isRawFile } from "./raw-import.js";
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
    "Choose an unadjusted TIFF, PNG or JPEG negative.",
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
      if (isRawFile(file))
        throw new Error(
          "For negative conversion, export an unadjusted TIFF from your RAW decoder first.",
        );
      const result = await importPhoto(file, {
        signal: controller.signal,
        onProgress: setStatus,
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
    <Modal
      title="Import Scanned Negative"
      onClose={onClose}
      className="negative-import-dialog"
    >
      <div className="negative-import">
        <p>
          Automatic conversion estimates colour balance from the image. No white
          or film-border sample is required.
        </p>
        <div className="negative-import-controls">
          <button onClick={() => picker.current?.click()} disabled={busy}>
            Choose Negative…
          </button>
          <label>
            <input
              type="checkbox"
              checked={monochrome}
              disabled={busy}
              onChange={(e) => setMonochrome(e.target.checked)}
            />{" "}
            Black &amp; white
          </label>
          <button
            disabled={!positive || busy}
            aria-pressed={negative}
            onClick={() => setNegative((v) => !v)}
          >
            {negative ? "Show Positive" : "Show Negative"}
          </button>
        </div>
        <input
          ref={picker}
          type="file"
          accept=".tif,.tiff,.png,.jpg,.jpeg"
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
          <button onClick={onClose}>Cancel</button>
          <button onClick={importPositive} disabled={!plan || busy}>
            Import Positive
          </button>
        </div>
      </div>
    </Modal>
  );
}
