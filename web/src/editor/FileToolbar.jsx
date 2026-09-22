import FotufilmBrand from "./FotufilmBrand.jsx";
import { Icon } from "../icons.jsx";
import ImportMenu from "./ImportMenu.jsx";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { useEditor } from "./EditorContext.jsx";
export default function FileToolbar() {
  const { filmOpen, setFilmOpen, setInspectorOpen, compactLayout } =
    useEditor();
  return (
    <div className="toolbar-leading">
      <TooltipTrigger>
        <ToggleButton
          onPress={() => {
            setFilmOpen((v) => !v);
            if (compactLayout) setInspectorOpen(false);
          }}
          data-panel-toggle="film"
          aria-expanded={filmOpen}
          aria-label={"Toggle film sidebar"}
          size={"S"}
          isQuiet
          isSelected={filmOpen}
        >
          <Icon name={"sidebar"} />
        </ToggleButton>
        <Tooltip>{"Toggle film sidebar"}</Tooltip>
      </TooltipTrigger>
      <FotufilmBrand compact className="toolbar-brand" />
      <ImportMenu />
    </div>
  );
}
