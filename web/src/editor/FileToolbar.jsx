import { Icon } from "../icons.jsx";
import ImportMenu from "./ImportMenu.jsx";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { useEditor } from "./EditorContext.jsx";
export default function FileToolbar() {
  const { filmOpen, setFilmOpen, setInspectorOpen } = useEditor();
  return (
    <div className="toolbar-leading">
      <TooltipTrigger>
        <ToggleButton
          onPress={() => {
            setFilmOpen((v) => !v);
            if (window.innerWidth < 834) setInspectorOpen(false);
          }}
          aria-label={"Toggle film sidebar"}
          size={"S"}
          isQuiet
          isSelected={filmOpen}
        >
          <Icon name={"sidebar"} />
        </ToggleButton>
        <Tooltip>{"Toggle film sidebar"}</Tooltip>
      </TooltipTrigger>
      <span className="app-name">Fotufilm</span>
      <ImportMenu />
    </div>
  );
}
