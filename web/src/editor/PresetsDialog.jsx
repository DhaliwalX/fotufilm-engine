import { useState } from "react";
import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Button } from "@react-spectrum/s2/Button";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";

// Manage Presets…: the saved presets, each applied or deleted here.
export default function PresetsDialog() {
  const {
    editSettings,
    applyPreset,
    deletePreset,
    setDialog,
    active,
    exporting,
  } = useEditor();
  const [doomed, setDoomed] = useState(null);
  if (doomed)
    return (
      <Dialog aria-label="Delete Preset" size="S">
        <Heading>{`Delete “${doomed.name}”?`}</Heading>
        <Content>
          <div className="dialog-actions">
            <Button
              size="S"
              variant="secondary"
              onPress={() => setDoomed(null)}
            >
              {"Cancel"}
            </Button>
            <Button
              size="S"
              variant="negative"
              onPress={() => {
                deletePreset(doomed.id);
                setDoomed(null);
              }}
            >
              {"Delete"}
            </Button>
          </div>
        </Content>
      </Dialog>
    );
  return (
    <Dialog aria-label="Presets" isDismissible size="M">
      <Heading>{"Presets"}</Heading>
      <Content>
        {editSettings.presets.length ? (
          <ul className="presets">
            {editSettings.presets.map((preset) => (
              <li key={preset.id}>
                <span>{preset.name}</span>
                <Button
                  size="S"
                  variant="secondary"
                  isDisabled={!active || exporting}
                  onPress={() => {
                    applyPreset(preset.id);
                    setDialog(null);
                  }}
                >
                  {"Apply"}
                </Button>
                <TooltipTrigger>
                  <ActionButton
                    size="S"
                    isQuiet
                    aria-label={`Delete ${preset.name}`}
                    onPress={() => setDoomed(preset)}
                  >
                    <Icon name="delete" />
                  </ActionButton>
                  <Tooltip>{"Delete"}</Tooltip>
                </TooltipTrigger>
              </li>
            ))}
          </ul>
        ) : (
          <p className="medium-detail">{"No presets yet."}</p>
        )}
      </Content>
    </Dialog>
  );
}
