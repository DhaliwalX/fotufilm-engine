import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";
import FotufilmBrand from "./FotufilmBrand.jsx";
import ImportMenu from "./ImportMenu.jsx";
import { useEditor } from "./EditorContext.jsx";

export default function FileToolbar() {
  const { libraryOpen, setLibraryOpen, exporting } = useEditor();
  return (
    <div className="toolbar-leading">
      <FotufilmBrand compact className="toolbar-brand" />
      <TooltipTrigger>
        <ToggleButton
          aria-label="Library (L)"
          size="S"
          isQuiet
          isSelected={libraryOpen}
          isDisabled={exporting}
          onChange={setLibraryOpen}
        >
          <Icon name="library" />
        </ToggleButton>
        <Tooltip>Library (L)</Tooltip>
      </TooltipTrigger>
      <ImportMenu />
    </div>
  );
}
