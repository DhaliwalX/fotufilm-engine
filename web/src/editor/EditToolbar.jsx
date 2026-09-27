import { Icon } from "../icons.jsx";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { useEditor } from "./EditorContext.jsx";
import OptionsMenu from "./OptionsMenu.jsx";
import { filmNamer, redoTitle, undoTitle } from "../edit-history.js";
import { shortcutLabel } from "../shortcut-label.js";
export default function EditToolbar() {
  const {
    toggleInspector,
    resetEdits,
    exporting,
    active,
    inspectorOpen,
    histogram,
    setHistogram,
    dispatch,
    history,
    setDialog,
    stocks,
  } = useEditor();
  // What Undo and Redo will change, as the Edit menu names it.
  const filmName = filmNamer(stocks);
  return (
    <div className="toolbar-trailing">
      <TooltipTrigger>
        <ToggleButton
          onPress={() => setHistogram((v) => !v)}
          isDisabled={!active}
          aria-label={"Histogram (H)"}
          size={"S"}
          isQuiet
          isSelected={histogram}
        >
          <Icon name={"histogram"} />
        </ToggleButton>
        <Tooltip>{"Histogram (H)"}</Tooltip>
      </TooltipTrigger>
      <span className="toolbar-divider" />
      <TooltipTrigger>
        <ActionButton
          onPress={() =>
            dispatch({
              type: "undo",
            })
          }
          isDisabled={!history.past.length || exporting}
          aria-label={`Undo (${shortcutLabel("⌘Z")})`}
          size={"S"}
          isQuiet
        >
          <Icon name={"undo"} />
        </ActionButton>
        <Tooltip>{`${undoTitle(history, filmName)} (${shortcutLabel("⌘Z")})`}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ActionButton
          onPress={() =>
            dispatch({
              type: "redo",
            })
          }
          isDisabled={!history.future.length || exporting}
          aria-label={`Redo (${shortcutLabel("⇧⌘Z")})`}
          size={"S"}
          isQuiet
        >
          <Icon name={"redo"} />
        </ActionButton>
        <Tooltip>{`${redoTitle(history, filmName)} (${shortcutLabel("⇧⌘Z")})`}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ActionButton
          onPress={resetEdits}
          isDisabled={!active || exporting}
          aria-label={"Reset all edits"}
          size={"S"}
          isQuiet
        >
          <Icon name={"reset"} />
        </ActionButton>
        <Tooltip>{"Reset all edits"}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ActionButton
          onPress={() => setDialog("export")}
          isDisabled={!active || !stocks.length || exporting}
          aria-label={`Export (${shortcutLabel("⌘S")})`}
          size={"S"}
          isQuiet
        >
          <Icon name={"export"} />
        </ActionButton>
        <Tooltip>{`Export (${shortcutLabel("⌘S")})`}</Tooltip>
      </TooltipTrigger>
      <OptionsMenu />
      <TooltipTrigger>
        <ToggleButton
          onPress={toggleInspector}
          data-panel-toggle="inspector"
          aria-expanded={inspectorOpen}
          aria-label={"Toggle adjustments"}
          size={"S"}
          isQuiet
          isSelected={inspectorOpen}
        >
          <Icon name={"inspector"} />
        </ToggleButton>
        <Tooltip>{"Toggle adjustments"}</Tooltip>
      </TooltipTrigger>
    </div>
  );
}
