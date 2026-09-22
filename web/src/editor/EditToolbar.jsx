import { Icon } from "../icons.jsx";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { defaultEdit } from "../editor-state.js";
import { useEditor } from "./EditorContext.jsx";
import OptionsMenu from "./OptionsMenu.jsx";
export default function EditToolbar() {
  const {
    setFilmOpen,
    setInspectorOpen,
    exporting,
    active,
    inspectorOpen,
    histogram,
    setHistogram,
    dispatch,
    history,
    edit,
    setStage,
    setDifference,
    setDialog,
    stocks,
  } = useEditor();
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
          aria-label={"Undo (⌘Z)"}
          size={"S"}
          isQuiet
        >
          <Icon name={"undo"} />
        </ActionButton>
        <Tooltip>{"Undo (⌘Z)"}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ActionButton
          onPress={() =>
            dispatch({
              type: "redo",
            })
          }
          isDisabled={!history.future.length || exporting}
          aria-label={"Redo (⇧⌘Z)"}
          size={"S"}
          isQuiet
        >
          <Icon name={"redo"} />
        </ActionButton>
        <Tooltip>{"Redo (⇧⌘Z)"}</Tooltip>
      </TooltipTrigger>
      <TooltipTrigger>
        <ActionButton
          onPress={() => {
            dispatch({
              type: "edit",
              patch: defaultEdit(edit.stock),
              restoring: true,
            });
            setStage(null);
            setDifference(false);
          }}
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
          aria-label={"Export (⌘S)"}
          size={"S"}
          isQuiet
        >
          <Icon name={"export"} />
        </ActionButton>
        <Tooltip>{"Export (⌘S)"}</Tooltip>
      </TooltipTrigger>
      <OptionsMenu />
      <TooltipTrigger>
        <ToggleButton
          onPress={() => {
            setInspectorOpen((v) => !v);
            if (window.innerWidth < 834) setFilmOpen(false);
          }}
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
