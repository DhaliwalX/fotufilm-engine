import { useRef } from "react";
import { Selector } from "@astryxdesign/core/Selector";
import { Switch } from "@astryxdesign/core/Switch";
import { Button } from "@astryxdesign/core/Button";
import { Adjustment } from "./EditorControls.jsx";
import { catalogueSlider } from "./editor-catalogue.js";
import {
  PROFILE_CONTROLS,
  profileDefault,
  profileControl,
  profileControlAvailable,
} from "./profile-settings.js";

function SpectrumCurve({ control, values, onChange, onEnd, disabled }) {
  const drag = useRef(null),
    curve = control.curve;
  const x = (nm) =>
    12 + ((nm - curve.domainMin) / (curve.domainMax - curve.domainMin)) * 256;
  const y = (value) => 8 + ((curve.max - value) / (curve.max - curve.min)) * 76;
  const update = (index, value) =>
    onChange(
      values.map((v, i) =>
        i === index
          ? Math.min(
              curve.max,
              Math.max(curve.min, Math.round(value * 10) / 10),
            )
          : v,
      ),
    );
  const move = (event) => {
    if (drag.current === null || disabled) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const position = ((event.clientY - rect.top) / rect.height) * 108;
    update(
      drag.current,
      curve.max - ((position - 8) / 76) * (curve.max - curve.min),
    );
  };
  return (
    <div className="spectrum-control" title={control.detail}>
      <div className="adjustment-label">
        <span>{control.title}</span>
        <Button
          label={`Reset ${control.title}`}
          size="sm"
          variant="ghost"
          isDisabled={disabled}
          onClick={() => {
            onChange(profileDefault(control));
            onEnd();
          }}
        >
          Reset
        </Button>
      </div>
      <svg
        viewBox="0 0 280 108"
        role="group"
        aria-label={control.title}
        onPointerDown={(event) => {
          if (disabled) return;
          event.preventDefault();
          const rect = event.currentTarget.getBoundingClientRect();
          const px = ((event.clientX - rect.left) / rect.width) * 280;
          drag.current = curve.handles.reduce(
            (best, nm, i) =>
              Math.abs(x(nm) - px) < Math.abs(x(curve.handles[best]) - px)
                ? i
                : best,
            0,
          );
          event.currentTarget.setPointerCapture(event.pointerId);
          move(event);
        }}
        onPointerMove={move}
        onPointerUp={() => {
          drag.current = null;
          onEnd();
        }}
        onPointerCancel={() => {
          drag.current = null;
          onEnd();
        }}
      >
        {[curve.min, 0, curve.max].map((v) => (
          <line
            key={v}
            x1="12"
            x2="268"
            y1={y(v)}
            y2={y(v)}
            className={v === 0 ? "curve-zero" : "curve-grid"}
          />
        ))}
        <polyline
          points={curve.handles
            .map((nm, i) => `${x(nm)},${y(values[i])}`)
            .join(" ")}
          className="curve-line"
        />
        {curve.handles.map((nm, i) => (
          <g key={nm}>
            <circle
              cx={x(nm)}
              cy={y(values[i])}
              r="4"
              role="slider"
              tabIndex={disabled ? -1 : 0}
              aria-label={`${control.title} ${nm} nm`}
              aria-valuemin={curve.min}
              aria-valuemax={curve.max}
              aria-valuenow={values[i]}
              aria-valuetext={`${values[i]} EV`}
              aria-disabled={disabled}
              onKeyDown={(event) => {
                if (
                  disabled ||
                  !["ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)
                )
                  return;
                event.preventDefault();
                update(
                  i,
                  event.key === "Home"
                    ? curve.min
                    : event.key === "End"
                      ? curve.max
                      : values[i] + (event.key === "ArrowUp" ? 0.1 : -0.1),
                );
                onEnd();
              }}
            />
            <text x={x(nm)} y="103" textAnchor="middle">
              {nm}
            </text>
          </g>
        ))}
      </svg>
    </div>
  );
}

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
          label={c.title}
          value={value}
          isDisabled={inactive}
          onChange={(next) => {
            onEnd();
            change(next);
            onEnd();
          }}
        />
      );
    if (c.kind === "chips")
      return (
        <Selector
          key={c.field}
          label={c.title}
          size="sm"
          width="100%"
          isDisabled={inactive}
          value={String(value)}
          options={c.chips.map((choice) => ({
            value: String(choice.value),
            label: choice.label,
          }))}
          onChange={(next) => {
            onEnd();
            change(Number(next));
            onEnd();
          }}
        />
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
            <Button
              label="Use Film Return"
              size="sm"
              variant="ghost"
              isDisabled={
                inactive || !Object.hasOwn(edit.profile || {}, c.field)
              }
              onClick={() => {
                onEnd();
                onReset(c.field);
                onEnd();
              }}
            >
              Use Film Return
            </Button>
          )}
        </div>
      );
    }
    if (!c.choices.some((choice) => choice.id === value))
      value = profileDefault(c);
    return (
      <Selector
        key={c.field}
        label={c.title}
        size="sm"
        width="100%"
        isDisabled={inactive}
        value={value}
        options={c.choices.map((choice) => ({
          value: choice.id,
          label: choice.label,
        }))}
        onChange={(next) => {
          onEnd();
          change(next);
          onEnd();
        }}
      />
    );
  });
}
