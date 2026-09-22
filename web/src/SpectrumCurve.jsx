import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useRef } from "react";
import { profileDefault } from "./profile-settings.js";
export default function SpectrumCurve({
  control,
  values,
  onChange,
  onEnd,
  disabled,
}) {
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
        <ActionButton
          size="S"
          isDisabled={disabled}
          onPress={() => {
            onChange(profileDefault(control));
            onEnd();
          }}
          isQuiet
        >{`Reset ${control.title}`}</ActionButton>
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
