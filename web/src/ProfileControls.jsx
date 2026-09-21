import { Selector } from "@astryxdesign/core/Selector";
import { Adjustment } from "./EditorControls.jsx";
import { catalogueSlider } from "./editor-catalogue.js";
import { PROFILE_CONTROLS, profileDefault } from "./profile-settings.js";

export default function ProfileControls({
  fields,
  edit,
  stock,
  onChange,
  onEnd,
  disabled,
}) {
  return PROFILE_CONTROLS.filter(
    (c) => fields.includes(c.field) && stock?.available.includes(c.field),
  ).map((c) =>
    c.scale ? (
      <Adjustment
        key={c.field}
        slider={catalogueSlider(c.field, "", c.field === "expired" ? 1 : 0.01)}
        value={edit.profile?.[c.field] ?? profileDefault(c)}
        disabled={disabled}
        onChange={(value) => onChange(c.field, value)}
        onEnd={onEnd}
      />
    ) : (
      <Selector
        key={c.field}
        label={c.title}
        size="sm"
        width="100%"
        isDisabled={disabled}
        value={edit.profile?.[c.field] ?? profileDefault(c)}
        options={c.choices.map((choice) => ({
          value: choice.id,
          label: choice.label,
        }))}
        onChange={(value) => {
          onEnd();
          onChange(c.field, value);
          onEnd();
        }}
      />
    ),
  );
}
