import { useState } from "react";
import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { Button } from "@react-spectrum/s2/Button";
import { TextField } from "@react-spectrum/s2/TextField";
import { PROFILE_CONTROLS, profileDefault } from "../profile-settings.js";
import { BAND_FIELDS, editBands, saveBandSet, useBandSets } from "../band-sets.js";
import { useEditor } from "./EditorContext.jsx";

const [RED, GREEN, BLUE] = BAND_FIELDS.map((field) =>
  profileDefault(PROFILE_CONTROLS.find((c) => c.field === field)),
);

// Save Bands…: the photo's receiver bands under a name, for any photo on this device.
export default function BandSetDialog() {
  const { edit, setDialog } = useEditor();
  const sets = useBandSets();
  const [name, setName] = useState("");
  const trimmed = name.trim();
  const replaces = sets.some((set) => set.name === trimmed);
  const bands = editBands(edit.profile, { red: RED, green: GREEN, blue: BLUE });
  const save = () => {
    if (!trimmed) return;
    saveBandSet(trimmed, bands);
    setDialog(null);
  };
  return (
    <Dialog aria-label="Save Bands" size="S">
      <Heading>Save Bands</Heading>
      <Content>
        <form
          className="settings-chooser"
          onSubmit={(event) => {
            event.preventDefault();
            save();
          }}
        >
          <TextField
            label="Name"
            autoFocus
            value={name}
            onChange={setName}
            description={
              replaces
                ? "Replaces the set of this name."
                : `${bands.red} / ${bands.green} / ${bands.blue} nm`
            }
          />
          <div className="dialog-actions">
            <span className="dialog-actions-spacer" />
            <Button size="S" variant="secondary" onPress={() => setDialog(null)}>
              {"Cancel"}
            </Button>
            <Button size="S" variant="accent" type="submit" isDisabled={!trimmed}>
              {"Save"}
            </Button>
          </div>
        </form>
      </Content>
    </Dialog>
  );
}
