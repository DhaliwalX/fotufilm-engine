import SpectrumCurve from "./SpectrumCurve.jsx";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { Switch } from "@react-spectrum/s2/Switch";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Adjustment } from "./Adjustment.jsx";
import { catalogueSlider } from "./editor-catalogue.js";
import {
  PROFILE_CONTROLS,
  profileDefault,
  profileControl,
  profileControlAvailable,
} from "./profile-settings.js";
export default function ProfileControls({
  fields,
  edit,
  stock,
  onChange,
  onReset,
  onEnd,
  disabled,
}) {
  return PROFILE_CONTROLS.filter(
    (c) => fields.includes(c.field) && profileControlAvailable(c, edit, stock),
  ).map((base) => {
    const c = profileControl(base, edit, stock);
    const inactive =
      disabled ||
      ([
        "printerLamp",
        "printerExposure",
        "printerMagenta",
        "printerYellow",
      ].includes(c.field) &&
        !edit.profile?.printerEnabled) ||
      (c.field === "printCorrection" && edit.profile?.printerEnabled);
    let value = edit.profile?.[c.field] ?? profileDefault(c);
    const change = (next) => onChange(c.field, next);
    if (c.curve)
      return (
        <SpectrumCurve
          key={c.field}
          control={c}
          values={value}
          onChange={change}
          onEnd={onEnd}
          disabled={inactive}
        />
      );
    if (c.kind === "toggle")
      return (
        <Switch
          key={c.field}
          isSelected={value}
          isDisabled={inactive}
          onChange={(next) => {
            onEnd();
            change(next);
            onEnd();
          }}
        >
          {c.title}
        </Switch>
      );
    if (c.kind === "chips")
      return (
        <Picker
          key={c.field}
          label={c.title}
          size="S"
          isDisabled={inactive}
          value={String(value)}
          onChange={(next) => {
            onEnd();
            change(Number(next));
            onEnd();
          }}
          UNSAFE_style={{
            width: "100%",
          }}
        >
          {c.chips
            .map((choice) => ({
              value: String(choice.value),
              label: choice.label,
            }))
            .map((option) => (
              <PickerItem
                id={option.value}
                key={option.value}
                isDisabled={option.disabled}
              >
                {option.label}
              </PickerItem>
            ))}
        </Picker>
      );
    if (c.scale) {
      const factor = c.scale.unit === "percent" ? 100 : 1;
      const slider = {
        ...catalogueSlider(c.field, "", c.field === "expired" ? 1 : 0.01),
        min: c.scale.min * factor,
        max: c.scale.max * factor,
        def: c.scale.neutral * factor,
        step: factor === 100 ? 1 : c.scale.stops.length ? 1 : 0.01,
        unit: factor === 100 ? "%" : catalogueSlider(c.field, "").unit,
      };
      const stops = c.scale.stops;
      if (c.field === "push" && !stops.includes(value)) value = c.scale.neutral;
      return (
        <div key={c.field} title={c.detail}>
          <Adjustment
            slider={slider}
            value={value * factor}
            disabled={inactive}
            onEnd={onEnd}
            onChange={(next) => {
              const v = next / factor;
              change(
                stops.length
                  ? stops.reduce((best, stop) =>
                      Math.abs(stop - v) < Math.abs(best - v) ? stop : best,
                    )
                  : v,
              );
            }}
          />
          {c.field === "halationReturn" && (
            <ActionButton
              size="S"
              isDisabled={
                inactive || !Object.hasOwn(edit.profile || {}, c.field)
              }
              onPress={() => {
                onEnd();
                onReset(c.field);
                onEnd();
              }}
              isQuiet
            >
              {"Use Film Return"}
            </ActionButton>
          )}
        </div>
      );
    }
    if (!c.choices.some((choice) => choice.id === value))
      value = profileDefault(c);
    return (
      <Picker
        key={c.field}
        label={c.title}
        size="S"
        isDisabled={inactive}
        value={value}
        onChange={(next) => {
          onEnd();
          change(next);
          onEnd();
        }}
        UNSAFE_style={{
          width: "100%",
        }}
      >
        {c.choices
          .map((choice) => ({
            value: choice.id,
            label: choice.label,
          }))
          .map((option) => (
            <PickerItem
              id={option.value}
              key={option.value}
              isDisabled={option.disabled}
            >
              {option.label}
            </PickerItem>
          ))}
      </Picker>
    );
  });
}
