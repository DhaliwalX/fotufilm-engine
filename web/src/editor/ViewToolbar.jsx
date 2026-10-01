import { Icon } from "../icons.jsx";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { useEditor } from "./EditorContext.jsx";
import { usePhotoView, zoomReach } from "../photo-view.js";
// Follows a pinch frame by frame, on its own.
function ZoomReadout({ photoView }) {
  const { zoom, readout } = usePhotoView(photoView);
  return (
    <span className="zoom-readout">{zoom === 1 ? "Fit" : `${readout}%`}</span>
  );
}
export default function ViewToolbar() {
  const {
    exporting,
    active,
    cropMode,
    photoView,
    panel,
    inspectorOpen,
    setInspector,
    rawWidth,
    rawHeight,
  } = useEditor();
  // Renders again only as the view crosses fit or the largest zoom.
  const reach = usePhotoView(photoView, zoomReach);
  return (
    <div className="toolbar-zoom">
      <TooltipTrigger>
        <ActionButton
          onPress={photoView.zoomOut}
          isDisabled={!active || reach === "fit" || cropMode}
          aria-label={"Zoom out"}
          size={"S"}
          isQuiet
        >
          <Icon name={"minus"} />
        </ActionButton>
        <Tooltip>{"Zoom out"}</Tooltip>
      </TooltipTrigger>
      <ZoomReadout photoView={photoView} />
      <TooltipTrigger>
        <ActionButton
          onPress={photoView.zoomIn}
          isDisabled={!active || reach === "max" || cropMode}
          aria-label={"Zoom in"}
          size={"S"}
          isQuiet
        >
          <Icon name={"plus"} />
        </ActionButton>
        <Tooltip>{"Zoom in"}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ActionButton
          onPress={photoView.fit}
          isDisabled={!active || reach === "fit"}
          aria-label={"Zoom to fit (0)"}
          size={"S"}
          isQuiet
        >
          <Icon name={"fit"} />
        </ActionButton>
        <Tooltip>{"Zoom to fit (0)"}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ToggleButton
          onPress={() => setInspector("selective")}
          isDisabled={!active || exporting || !!active?.image.video}
          aria-label={"Selective"}
          size={"S"}
          isQuiet
          isSelected={panel === "selective" && inspectorOpen}
        >
          <Icon name={"selective"} />
        </ToggleButton>
        <Tooltip>{"Selective"}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ToggleButton
          onPress={() => setInspector("crop")}
          isDisabled={!active || exporting}
          aria-label={"Crop"}
          size={"S"}
          isQuiet
          isSelected={panel === "crop" && inspectorOpen}
        >
          <Icon name={"crop"} />
        </ToggleButton>
        <Tooltip>{"Crop"}</Tooltip>
      </TooltipTrigger>
      <span
        className="pixel-readout"
        title={
          active?.image.raw
            ? active.image.raw.profile
              ? `Camera spectral profile: ${active.image.raw.profile.name} · estimated ${Math.round(active.image.raw.profile.kelvin)} K`
              : "RAW decoder color · no matching camera spectral correction"
            : undefined
        }
      >
        {active?.image.video
          ? "Video · "
          : active?.image.hdr
            ? "HDR · "
            : active?.image.deep
              ? `${active.image.deep.format} · ${active.image.deep.bitDepth}-bit · `
              : active?.image.linear
                ? "EXR · linear · "
                : active?.image.raw
                  ? "RAW · "
                  : ""}
        {active ? `${((rawWidth * rawHeight) / 1000000).toFixed(1)} MP` : ""}
      </span>
    </div>
  );
}
