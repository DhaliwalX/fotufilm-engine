import { NumberField } from "@react-spectrum/s2/NumberField";
import { Button } from "@react-spectrum/s2/Button";
import { PROFILE_CONTROLS, profileDefault, withProfileField } from "../profile-settings.js";
import { controlHelp } from "./ControlHelp.jsx";
import { useEditor } from "./EditorContext.jsx";

const BANDS = ["screenRedBand", "screenGreenBand", "screenBlueBand"].map((field) =>
  PROFILE_CONTROLS.find((c) => c.field === field),
);

// The peaks of the three bands Digital Reference reads a colour negative through, typed in nm.
export default function ReceiverBands({ id }) {
  const { active, exporting, layeredLocked, edit, setProfile, patch, endEdit } = useEditor();
  const disabled = exporting || !active || layeredLocked;
  const moved = BANDS.some((c) => edit.profile?.[c.field] != null);
  return (
    <div className="receiver-bands" id={id}>
      {BANDS.map((c) => (
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
              value={edit.profile?.[c.field] ?? profileDefault(c)}
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
      <Button
        size="S"
        variant="secondary"
        fillStyle="outline"
        isDisabled={disabled || !moved}
        onPress={() => {
          endEdit();
          let profile = edit.profile;
          for (const c of BANDS) profile = withProfileField(profile, c.field, undefined);
          patch({ profile });
        }}
      >
        Reset Bands
      </Button>
    </div>
  );
}
