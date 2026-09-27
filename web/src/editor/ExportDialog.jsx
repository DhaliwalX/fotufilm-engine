import { useEffect } from "react";
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
import { exportMaxEdge, exportSizeOptions } from "../export-sizes.js";
import { setAppSetting, useAppSetting } from "../app-settings.js";

const IMAGE_TYPES = [
  { id: "image/png", label: "PNG" },
  { id: "image/tiff", label: "TIFF · 16-bit" },
  { id: "image/jpeg", label: "JPEG" },
  { id: "image/webp", label: "WebP" },
];
const LOSSY = ["image/jpeg", "image/webp", "image/heic"];
/** Export Original's format: the camera RAW file itself (`backend.exportOriginal`). */
export const ORIGINAL = "original";

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
    patch,
    edit,
    framedSize,
    cropSize,
    width,
    height,
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
  const video = !!active?.image.video;
  const originalAvailable =
    !video && !!backend.exportOriginal && !!active?.image.original;
  const original = originalAvailable && exportType === ORIGINAL;
  // A photograph with no camera RAW behind it has no original to export.
  useEffect(() => {
    if (exportType === ORIGINAL && !originalAvailable && !video)
      setExportType((backend.imageExportTypes ?? IMAGE_TYPES)[0].id);
  }, [exportType, originalAvailable, video, backend, setExportType]);
  const sizes = exportSizeOptions(width, height, video, cropSize);
  // The settings of the last export of this kind, offered back as the Mac app offers them.
  const last = useAppSetting(video ? "lastVideoExport" : "lastPhotoExport");
  const videoHDR = useAppSetting("videoHDR") === true;
  const setVideoHDR = (value) => setAppSetting("videoHDR", value);
  const videoBitrate = useAppSetting("videoBitrate");
  // The clip's cadence, kept with its edit as the Mac app keeps it: choosing a rate here sets it.
  const videoFrameRate = edit.video?.frameRate ?? null;
  const setVideoFrameRate = (frameRate) =>
    patch({ video: { ...edit.video, frameRate } });
  const videoProcessing = useAppSetting("videoProcessing");
  const current = video
    ? {
        format: videoFormat,
        quality: videoQuality,
        bitrate: videoBitrate,
        frameRate: videoFrameRate,
        ...(backend.videoProcessing ? { processing: videoProcessing } : {}),
        size: exportSize,
      }
    : { type: exportType, size: exportSize, quality, metadata: exportMetadata };
  const applyLast = () => {
    if (video) {
      setVideoFormat(last.format);
      setVideoQuality(last.quality);
      if (last.bitrate) setAppSetting("videoBitrate", last.bitrate);
      if (last.processing) setAppSetting("videoProcessing", last.processing);
      setVideoFrameRate(last.frameRate ?? null);
    } else {
      setExportType(last.type);
      setQuality(last.quality);
      setExportMetadata(last.metadata);
    }
    setExportSize(last.size);
  };
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
          {last && JSON.stringify(last) !== JSON.stringify(current) && (
            <Button size="S" variant={"secondary"} onPress={applyLast}>
              {"Use Last Export Settings"}
            </Button>
          )}
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
                [
                  ...(backend.imageExportTypes ?? IMAGE_TYPES),
                  ...(originalAvailable ? [{ id: ORIGINAL, label: "Original RAW" }] : []),
                ].map(({ id, label }) => (
                  <PickerItem key={id} id={id}>
                    {label}
                  </PickerItem>
                ))
              )}
            </Picker>
          </div>
          {original ? (
            <p className="export-detail">
              Copies the original camera RAW file. Fotufilm edits and the
              resolution setting are not included.
            </p>
          ) : (
            <>
          <div className="select-row">
            Size
            <Picker
              aria-label="Size"
              value={sizes.some(({ id }) => id === exportSize) ? exportSize : "full"}
              onChange={(e) => setExportSize(e)}
              size={"S"}
            >
              {sizes.map(({ id, label, detail }) => (
                <PickerItem key={id} id={id} textValue={label}>
                  {detail ? `${label} · ${detail}` : label}
                </PickerItem>
              ))}
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
          {active?.image.video && videoType?.hdr && (
            <Switch isSelected={videoHDR} onChange={setVideoHDR} size="S">
              HDR
            </Switch>
          )}
          {video && backend.videoFrameRates && (
            <div className="select-row">
              {VIDEO_LABELS.frameRate}
              <Picker
                aria-label={VIDEO_LABELS.frameRate}
                value={videoFrameRate == null ? "source" : String(videoFrameRate)}
                onChange={(id) => setVideoFrameRate(id === "source" ? null : Number(id))}
                size={"S"}
              >
                <PickerItem id="source">{VIDEO_LABELS.frameRateSource}</PickerItem>
                {backend.videoFrameRates.map((rate) => (
                  <PickerItem key={rate} id={String(rate)}>
                    {`${rate} fps`}
                  </PickerItem>
                ))}
              </Picker>
            </div>
          )}
          {video && backend.videoProcessing && (
            <div className="select-row">
              Processing
              <Picker
                aria-label="Processing"
                value={videoProcessing}
                onChange={(id) => setAppSetting("videoProcessing", id)}
                size={"S"}
              >
                <PickerItem id="full">Full</PickerItem>
                <PickerItem id="fast">Fast</PickerItem>
              </Picker>
            </div>
          )}
          {video && videoType?.quality !== false && backend.videoBitrates && (
            <div className="select-row">
              File Size
              <Picker
                aria-label="File Size"
                value={videoBitrate}
                onChange={(id) => setAppSetting("videoBitrate", id)}
                size={"S"}
              >
                {backend.videoBitrates.map(({ id, label }) => (
                  <PickerItem key={id} id={id}>
                    {label}
                  </PickerItem>
                ))}
              </Picker>
            </div>
          )}
          {video && videoType?.quality !== false && !backend.videoBitrates && (
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
                  exportMaxEdge(exportSize, width, height),
                ).width
              : (framedSize.plan?.placement.size.width ??
                Math.max(1, Math.round(cropSize.width * exportScale)))}{" "}
            ×{" "}
            {active?.image.video
              ? videoDimensions(
                  active.image,
                  edit,
                  exportMaxEdge(exportSize, width, height),
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
              ? `${videoType?.bits ?? 8}-bit${videoType?.hdr && videoHDR ? " HLG" : ""}`
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
            </>
          )}
        </fieldset>
        {!active?.image.video && !original && framedSize.error && (
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
            isDisabled={exporting && !active?.image.video && !backend.exportImageCancels}
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
            {exporting ? "Exporting…" : original ? "Export Original" : "Export"}
          </Button>
        </div>
      </Content>
    </Dialog>
  );
}
