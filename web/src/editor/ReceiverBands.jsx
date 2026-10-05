import { NumberField } from "@react-spectrum/s2/NumberField";
import { Button } from "@react-spectrum/s2/Button";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { Switch } from "@react-spectrum/s2/Switch";
import { PROFILE_CONTROLS, profileDefault, withProfileField } from "../profile-settings.js";
import { setAppSetting, useAppSetting } from "../app-settings.js";
import { BAND_FIELDS, deleteBandSet, editBands, sameBands, useBandSets } from "../band-sets.js";
import { controlHelp } from "./ControlHelp.jsx";
import { useEditor } from "./EditorContext.jsx";

const BANDS = BAND_FIELDS.map((field) => PROFILE_CONTROLS.find((c) => c.field === field));
const PAPER = { red: profileDefault(BANDS[0]), green: profileDefault(BANDS[1]), blue: profileDefault(BANDS[2]) };
const KEYS = ["red", "green", "blue"];

// The peaks of the three bands Digital Reference reads a colour film through, typed in nm, with
// the sets saved on this device and the bands new photos start on.
export default function ReceiverBands({ id }) {
  const { active, exporting, edit, setProfile, patch, endEdit, setDialog } = useEditor();
  const sets = useBandSets();
  const startingBands = useAppSetting("receiverBands");
  const disabled = exporting || !active;
  const current = editBands(edit.profile, PAPER);
  const moved = BANDS.some((c) => edit.profile?.[c.field] != null);
  const saved = sets.find((set) => sameBands(set, current));
  const apply = (bands) => {
    endEdit();
    let profile = edit.profile;
    BANDS.forEach((c, i) => {
      profile = withProfileField(profile, c.field, bands?.[KEYS[i]]);
    });
    patch({ profile });
  };
  return (
    <div className="receiver-bands" id={id}>
      {sets.length > 0 && (
        <Picker
          label="Saved Bands"
          size="S"
          isDisabled={disabled}
          placeholder="Unsaved"
          value={saved?.name ?? null}
          onChange={(name) => apply(sets.find((set) => set.name === name))}
          UNSAFE_style={{ width: "100%" }}
        >
          {sets.map((set) => (
            <PickerItem id={set.name} key={set.name} textValue={set.name}>
              {set.name}
            </PickerItem>
          ))}
        </Picker>
      )}
      {BANDS.map((c, i) => (
        <div className="receiver-band" key={c.field}>
          <span className="adjustment-name">
            {c.title}
            {controlHelp(c.title, c.detail)}
          </span>
          <div className="number-field">
            <NumberField
              aria-label={`${c.title} peak`}
              isDisabled={disabled}
              size="S"
              value={current[KEYS[i]]}
              minValue={c.scale.min}
              maxValue={c.scale.max}
              step={1}
              hideStepper
              onChange={(next) => {
                if (!Number.isFinite(next)) return;
                endEdit();
                setProfile(c.field, Math.min(Math.max(next, c.scale.min), c.scale.max));
                endEdit();
              }}
              UNSAFE_style={{ width: 64 }}
            />
            nm
          </div>
        </div>
      ))}
      <Switch
        size="S"
        isDisabled={disabled}
        isSelected={sameBands(startingBands, current)}
        onChange={(on) => setAppSetting("receiverBands", on ? current : null)}
      >
        Use for New Photos
      </Switch>
      <div className="receiver-band-actions">
        <Button
          size="S"
          variant="secondary"
          fillStyle="outline"
          isDisabled={disabled}
          onPress={() => setDialog("saveBands")}
        >
          Save Bands…
        </Button>
        {saved ? (
          <Button
            size="S"
            variant="secondary"
            fillStyle="outline"
            isDisabled={disabled}
            onPress={() => deleteBandSet(saved.name)}
          >
            Delete Set
          </Button>
        ) : null}
        <Button
          size="S"
          variant="secondary"
          fillStyle="outline"
          isDisabled={disabled || !moved}
          onPress={() => apply(null)}
        >
          Reset Bands
        </Button>
      </div>
    </div>
  );
}
