import useCompactLayout from "./useCompactLayout.js";
import { Slider } from "@react-spectrum/s2/Slider";
import { NumberField } from "@react-spectrum/s2/NumberField";
import { SLIDERS } from "./editor-state.js";
import { clamp } from "./color-controls.js";
export function Adjustment({
  slider,
  value,
  onChange,
  onEnd,
  disabled = false,
}) {
  const compactLayout = useCompactLayout();
  const accessibleLabel = slider.key.startsWith("grade")
    ? `${slider.group} ${slider.label}`
    : slider.label;
  const temperature = slider.key === "temperature";
  const rangeValue = temperature ? 1e6 / value : value;
  return (
    <div className="adjustment">
      <div className="adjustment-label">
        <span>{slider.label}</span>
        <div className="number-field">
          <NumberField
            aria-label={`${accessibleLabel} value`}
            isDisabled={disabled}
            size={compactLayout ? "L" : "S"}
            value={Number(value.toFixed(3))}
            minValue={slider.min}
            maxValue={slider.max}
            step={slider.step}
            onChange={(next) => {
              if (Number.isFinite(next))
                onChange(clamp(next, slider.min, slider.max));
            }}
            onBlur={onEnd}
            UNSAFE_style={{
              width: 88,
            }}
            hideStepper
            formatOptions={{
              maximumFractionDigits: 3,
            }}
          />
        </div>
      </div>
      <Slider
        size="S"
        UNSAFE_className="adjustment-slider"
        aria-label={accessibleLabel}
        isDisabled={disabled}
        minValue={temperature ? 1e6 / slider.max : slider.min}
        maxValue={temperature ? 1e6 / slider.min : slider.max}
        step={temperature ? 0.1 : slider.step}
        value={rangeValue}
        onChange={(next) =>
          onChange(temperature ? Math.round(1e6 / next) : next)
        }
        onChangeEnd={onEnd}
        onBlur={onEnd}
        onDoubleClick={() => {
          onChange(slider.def);
          onEnd?.();
        }}
      />
    </div>
  );
}
export function Adjustments({
  group,
  params,
  onChange,
  onEnd,
  disabled,
  hasFilm = true,
}) {
  return SLIDERS.filter(
    (s) => s.group === group && (hasFilm || s.availability !== "film"),
  ).map((slider) => (
    <Adjustment
      key={slider.key}
      slider={slider}
      disabled={disabled}
      value={params[slider.key]}
      onChange={(value) => onChange(slider.key, value)}
      onEnd={onEnd}
    />
  ));
}
