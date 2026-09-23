import { Icon } from "../icons.jsx";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { inspectorPanels } from "../editor-catalogue.js";
import { useEditor } from "./EditorContext.jsx";
export default function InspectorRail() {
  const {
    panel,
    setInspector,
    inspectorOpen,
    compactLayout,
    filmOpen,
    setFilmOpen,
  } = useEditor();
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
            onPress={() =>
              compactLayout && filmOpen && p.id === "film"
                ? setFilmOpen(false)
                : setInspector(p.id)
            }
            data-panel-toggle={p.id === "film" && compactLayout ? "film" : undefined}
            aria-label={p.title}
            size={"S"}
            isQuiet
            isSelected={
              compactLayout && filmOpen ? p.id === "film" : panel === p.id
            }
            aria-expanded={
              compactLayout
                ? p.id === "film"
                  ? filmOpen
                  : inspectorOpen && panel === p.id
                : undefined
            }
          >
            <Icon name={p.icon} />
            <span className="compact-panel-label">{p.title}</span>
          </ToggleButton>
          <Tooltip>{p.title}</Tooltip>
        </TooltipTrigger>
      ))}
    </nav>
  );
}
