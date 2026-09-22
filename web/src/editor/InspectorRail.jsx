import { Icon } from "../icons.jsx";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { inspectorPanels } from "../editor-catalogue.js";
import { useEditor } from "./EditorContext.jsx";
export default function InspectorRail() {
  const { panel, setInspector, inspectorOpen } = useEditor();
  return (
    <nav
      className="inspector-rail"
      inert={inspectorOpen}
      aria-hidden={inspectorOpen}
      aria-label="Adjustment panels"
    >
      {inspectorPanels.map((p) => (
        <TooltipTrigger key={p.id}>
          <ToggleButton
            key={p.id}
            onPress={() => setInspector(p.id)}
            aria-label={p.title}
            size={"S"}
            isQuiet
            isSelected={panel === p.id}
          >
            <Icon name={p.icon} />
          </ToggleButton>
          <Tooltip>{p.title}</Tooltip>
        </TooltipTrigger>
      ))}
    </nav>
  );
}
