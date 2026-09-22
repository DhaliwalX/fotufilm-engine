import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";

export default function PanelDismissButton({ panel }) {
  const { setFilmOpen, setInspectorOpen, endEdit } = useEditor();
  const label = panel === "film" ? "Close film library" : "Close adjustments";
  return (
    <span className="compact-panel-dismiss">
      <ActionButton
        aria-label={label}
        isQuiet
        size="M"
        onPress={(event) => {
          endEdit();
          (panel === "film" ? setFilmOpen : setInspectorOpen)(false);
          event.target
            .closest(".editor")
            ?.querySelector(`[data-panel-toggle="${panel}"]`)
            ?.focus({ preventScroll: true });
        }}
      >
        <Icon name="close" />
      </ActionButton>
    </span>
  );
}
