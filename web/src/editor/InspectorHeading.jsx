import PanelDismissButton from "./PanelDismissButton.jsx";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { inspectorPanels } from "../editor-catalogue.js";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";
const help = {
  film: "Load a stock and choose its format and character.",
  light: "Adjust the light and filters, then refine the colour grade.",
  develop: "Develop the film, then shape its grain and colour separation.",
  print: "Choose a print or scan, set its viewing light, and export.",
  selective: "Adjust a selected colour, area, or subject.",
  crop: "Frame and straighten the finished photograph.",
  pipeline: "Inspect each stage of the film development pipeline.",
};
export default function InspectorHeading() {
  const { panel } = useEditor();
  return (
    <div className="darkroom-heading">
      <h2>
        {panel === "crop"
          ? "Crop"
          : panel === "selective"
            ? "Selective"
            : "Darkroom"}
      </h2>
      <TooltipTrigger>
        <ActionButton
          aria-label={`Help for ${inspectorPanels.find((p) => p.id === panel)?.title || panel}`}
          size="S"
          isQuiet
        >
          <Icon name="help" />
        </ActionButton>
        <Tooltip>{help[panel]}</Tooltip>
      </TooltipTrigger>
      {["crop", "selective"].includes(panel) && <span>Canvas tool</span>}
      <PanelDismissButton panel="inspector" />
    </div>
  );
}
