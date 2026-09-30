import { useState } from "react";
import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { Button } from "@react-spectrum/s2/Button";
import { Checkbox } from "@react-spectrum/s2/Checkbox";
import { CheckboxGroup } from "@react-spectrum/s2/CheckboxGroup";
import { TextField } from "@react-spectrum/s2/TextField";
import { SETTINGS_SECTIONS } from "../edit-settings.js";
import { useEditor } from "./EditorContext.jsx";

// The inspector's sections under their tabs' titles: Film, Lens, Light & Color, Print, Frame.
const GROUPS = [...new Set(SETTINGS_SECTIONS.map((s) => s.group))].map(
  (group) => SETTINGS_SECTIONS.filter((s) => s.group === group),
);

// Copy Settings… and Save Preset…: which sections travel, and for a preset its name.
export default function SettingsSectionsDialog({ preset }) {
  const { editSettings, copySettings, savePreset, setDialog } = useEditor();
  const [sections, setSections] = useState(editSettings.sections);
  const [name, setName] = useState("");
  const replaces =
    preset && editSettings.presets.some((p) => p.name === name.trim());
  const ready = sections.length > 0 && (!preset || name.trim());
  const confirm = () => {
    if (!ready) return;
    if (preset) savePreset(name.trim(), sections);
    else copySettings(sections);
  };
  return (
    <Dialog aria-label={preset ? "Save Preset" : "Copy Settings"} size="M">
      <Heading>{preset ? "Save Preset" : "Copy Settings"}</Heading>
      <Content>
        <form
          className="settings-chooser"
          onSubmit={(event) => {
            event.preventDefault();
            confirm();
          }}
        >
          {preset && (
            <TextField
              label="Name"
              autoFocus
              value={name}
              onChange={setName}
              description={
                replaces ? "Replaces the preset of this name." : undefined
              }
            />
          )}
          <div className="settings-sections">
            {GROUPS.map((group) => (
              <CheckboxGroup
                key={group[0].group}
                label={group[0].groupTitle}
                value={sections.filter((id) => group.some((s) => s.id === id))}
                onChange={(chosen) =>
                  setSections([
                    ...sections.filter((id) => !group.some((s) => s.id === id)),
                    ...chosen,
                  ])
                }
              >
                {group.map((section) => (
                  <Checkbox key={section.id} value={section.id}>
                    {section.title}
                  </Checkbox>
                ))}
              </CheckboxGroup>
            ))}
          </div>
          <div className="dialog-actions">
            <Button
              size="S"
              variant="secondary"
              onPress={() => setSections(SETTINGS_SECTIONS.map((s) => s.id))}
            >
              {"Check All"}
            </Button>
            <Button
              size="S"
              variant="secondary"
              onPress={() => setSections([])}
            >
              {"Check None"}
            </Button>
            <span className="dialog-actions-spacer" />
            <Button
              size="S"
              variant="secondary"
              onPress={() => setDialog(null)}
            >
              {"Cancel"}
            </Button>
            <Button size="S" variant="accent" type="submit" isDisabled={!ready}>
              {preset ? "Save" : "Copy"}
            </Button>
          </div>
        </form>
      </Content>
    </Dialog>
  );
}
