import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";

export default function FilmSidebarToggle() {
  const { filmOpen, setFilmOpen, compactLayout, endEdit } = useEditor();
  return (
    <TooltipTrigger>
      <ToggleButton
        aria-label="Toggle film sidebar"
        aria-expanded={filmOpen}
        aria-controls="film-library-content"
        isSelected={filmOpen}
        isQuiet
        size="S"
        onPress={(event) => {
          endEdit();
          setFilmOpen((open) => !open);
          if (compactLayout && filmOpen)
            event.target.closest(".editor")
              ?.querySelector('[data-panel-toggle="film"]')
              ?.focus({ preventScroll: true });
        }}
      >
        <Icon name="sidebar" />
      </ToggleButton>
      <Tooltip>{filmOpen ? "Collapse films" : "Expand films"}</Tooltip>
    </TooltipTrigger>
  );
}
