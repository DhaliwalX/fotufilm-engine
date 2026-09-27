import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { PickerItem, Picker } from "@react-spectrum/s2/Picker";
import { Adjustment } from "../Adjustment.jsx";
import { VIDEO_LABELS } from "../generated/controls.js";
import { videoDimensions } from "../video-settings.js";
import { colorSpaceLabel } from "../canvas-color.js";
import { Button } from "@react-spectrum/s2/Button";
import { Switch } from "@react-spectrum/s2/Switch";
import { useEditor } from "./EditorContext.jsx";
import { METADATA_LABELS, useExportOptions } from "./useExportOptions.js";

const IMAGE_TYPES = [
  { id: "image/png", label: "PNG" },
  { id: "image/tiff", label: "TIFF · 16-bit" },
  { id: "image/jpeg", label: "JPEG" },
  { id: "image/webp", label: "WebP" },
];
const LOSSY = ["image/jpeg", "image/webp", "image/heic"];

/** The browser encoder's movie formats; a native backend lists its own. */
export function videoExportTypes(backend) {
  return (
    backend.videoExportTypes ?? [
      { id: "mp4", label: VIDEO_LABELS.mp4, quality: true },
      { id: "webm", label: VIDEO_LABELS.webm, quality: true },
    ]
  );
}

export default function ExportDialog() {
  const {
    backend,
    active,
    exporting,
    setDialog,
    videoFormat,
    exportType,
    setVideoFormat,
    setExportType,
    exportSize,
    setExportSize,
    quality,
    setQuality,
    videoQuality,
    setVideoQuality,
    edit,
    framedSize,
    cropSize,
    exportScale,
    status,
    videoExportController,
    exportClip,
    exportImage,
    exportMetadata,
    setExportMetadata,
    exportHDR,
    setExportHDR,
    stockId,
  } = useEditor();
  const options = useExportOptions({ backend, active, edit, stockId });
  const hdr = exportType === "image/heic" && options?.hdr === true && exportHDR;
  const videoType = active?.image.video
    ? videoExportTypes(backend).find(({ id }) => id === videoFormat)
    : null;
  return (
    <Dialog aria-label="Export image" isDismissible size={"M"}>
      <Heading>
        {active?.image.video ? VIDEO_LABELS.export : "Export image"}
      </Heading>
      <Content>
        <fieldset disabled={exporting}>
          <div className="select-row">
            Format
            <Picker
              aria-label="Format"
              value={active?.image.video ? videoFormat : exportType}
              onChange={(e) =>
                active?.image.video ? setVideoFormat(e) : setExportType(e)
              }
              size={"S"}
            >
              {active?.image.video ? (
                videoExportTypes(backend).map(({ id, label }) => (
                  <PickerItem key={id} id={id}>
                    {label}
                  </PickerItem>
                ))
              ) : (
                (backend.imageExportTypes ?? IMAGE_TYPES).map(({ id, label }) => (
                  <PickerItem key={id} id={id}>
                    {label}
                  </PickerItem>
                ))
              )}
            </Picker>
          </div>
          <div className="select-row">
            Size
            <Picker
              aria-label="Size"
              value={exportSize}
              onChange={(e) => setExportSize(e)}
              size={"S"}
            >
              <PickerItem id="full">Full resolution</PickerItem>
              <PickerItem id="3840">3840 px long edge</PickerItem>
              <PickerItem id="2048">2048 px long edge</PickerItem>
              <PickerItem id="1600">1600 px long edge</PickerItem>
            </Picker>
          </div>
          {!active?.image.video &&
            LOSSY.includes(exportType) && (
              <Adjustment
                slider={{
                  key: "quality",
                  label: "Quality",
                  min: 1,
                  max: 100,
                  step: 1,
                  def: 95,
                  unit: "%",
                }}
                disabled={exporting}
                value={quality}
                onChange={setQuality}
              />
            )}
          {!active?.image.video && options?.metadata && (
            <div className="select-row">
              Metadata
              <Picker
                aria-label="Metadata"
                value={exportMetadata}
                onChange={(e) => setExportMetadata(e)}
                size={"S"}
              >
                {options.metadata.map((id) => (
                  <PickerItem key={id} id={id}>
                    {METADATA_LABELS[id] ?? id}
                  </PickerItem>
                ))}
              </Picker>
            </div>
          )}
          {!active?.image.video &&
            exportType === "image/heic" &&
            options?.hdr && (
              <Switch isSelected={exportHDR} onChange={setExportHDR} size="S">
                HDR
              </Switch>
            )}
          {active?.image.video && videoType?.quality !== false && (
            <div className="select-row">
              Quality
              <Picker
                aria-label={VIDEO_LABELS.quality}
                value={videoQuality}
                onChange={(e) => setVideoQuality(e)}
                size={"S"}
              >
                <PickerItem id="medium">{VIDEO_LABELS.medium}</PickerItem>
                <PickerItem id="high">{VIDEO_LABELS.high}</PickerItem>
                <PickerItem id="very-high">{VIDEO_LABELS.veryHigh}</PickerItem>
              </Picker>
            </div>
          )}
          <p className="export-detail">
            {active?.image.video
              ? videoDimensions(
                  active.image,
                  edit,
                  exportSize === "full" ? Infinity : Number(exportSize),
                ).width
              : (framedSize.plan?.placement.size.width ??
                Math.max(1, Math.round(cropSize.width * exportScale)))}{" "}
            ×{" "}
            {active?.image.video
              ? videoDimensions(
                  active.image,
                  edit,
                  exportSize === "full" ? Infinity : Number(exportSize),
                ).height
              : (framedSize.plan?.placement.size.height ??
                Math.max(1, Math.round(cropSize.height * exportScale)))}{" "}
            pixels ·{" "}
            {colorSpaceLabel(
              active?.image.video
                ? (videoType?.colorSpace ?? "srgb")
                : exportType === "image/tiff"
                  ? "display-p3"
                  : backend.outputColorSpace({ type: exportType }),
            )}{" "}
            ·{" "}
            {active?.image.video
              ? `${videoType?.bits ?? 8}-bit`
              : exportType === "image/tiff"
                ? "16-bit"
                : hdr
                  ? "HDR"
                  : "8-bit"}
          </p>
          <p className="export-detail">
            {active?.image.video
              ? "Exports every frame in the trim range with the current film, crop, and adjustments. Writes directly to disk; no upload. Odd dimensions are padded by one pixel."
              : "Exports the finished image with the current crop and adjustments."}
          </p>
        </fieldset>
        {!active?.image.video && framedSize.error && (
          <p role="alert">{framedSize.error}</p>
        )}
        {exporting && <p role="status">{status || "Preparing export"}</p>}
        <div className="dialog-actions">
          <Button
            size="S"
            UNSAFE_className="secondary"
            onPress={() =>
              exporting
                ? videoExportController.current?.abort()
                : setDialog(null)
            }
            isDisabled={exporting && !active?.image.video}
            variant={"secondary"}
          >
            {"Cancel"}
          </Button>
          <Button
            size="S"
            onPress={active?.image.video ? exportClip : exportImage}
            isDisabled={exporting}
            variant={"accent"}
          >
            {exporting ? "Exporting…" : "Export"}
          </Button>
        </div>
      </Content>
    </Dialog>
  );
}
