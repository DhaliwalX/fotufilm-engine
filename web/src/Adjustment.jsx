import useCompactLayout from "./useCompactLayout.js";
import { Slider } from "@react-spectrum/s2/Slider";
import { NumberField } from "@react-spectrum/s2/NumberField";
import { SLIDERS } from "./editor-state.js";
import { clamp } from "./color-controls.js";
import { Glyph, sliderEnds } from "./glyphs.jsx";
import { controlDetail, controlHelp } from "./editor/ControlHelp.jsx";
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
  // What the slider's low and high ends look like, as the Mac app draws them beside the track.
  const ends = sliderEnds(slider.key);
  return (
    <div className="adjustment">
      <div className="adjustment-label">
        <span className="adjustment-name">
          {slider.label}
          {controlHelp(accessibleLabel, slider.detail ?? controlDetail(slider.key))}
        </span>
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
      <div className="adjustment-track">
        {ends && <Glyph name={ends.low} size={13} className="adjustment-end" />}
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
        {ends && <Glyph name={ends.high} size={13} className="adjustment-end" />}
      </div>
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
