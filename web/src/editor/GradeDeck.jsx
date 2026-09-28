import { useLayoutEffect, useRef, useState } from "react";
import {
  SegmentedControl,
  SegmentedControlItem,
} from "@react-spectrum/s2/SegmentedControl";
import { Button } from "@react-spectrum/s2/Button";
import { useEditor } from "./EditorContext.jsx";
import {
  GRADE_BANDS,
  GRADE_FIELDS,
  capsuleLevel,
  gradeFields,
  gradeIsNeutral,
  gradeReadout,
  levelReading,
  padBalance,
  padPoint,
  padReading,
} from "../grade-deck.js";

// Arrow keys move the pad and the level by this much; with Shift, by a tenth of it.
const STEP = 0.05;

/**
 * Follows one pointer from press to release: `place` gets each point in the element's own
 * coordinates, and one continuous edit covers the drag.
 */
function useDrag(place, endEdit) {
  const dragging = useRef(false);
  const at = (event) => {
    const box = event.currentTarget.getBoundingClientRect();
    place(event.clientX - box.left, event.clientY - box.top, box.width, box.height);
  };
  return {
    onPointerDown(event) {
      if (event.button !== 0) return;
      event.currentTarget.setPointerCapture(event.pointerId);
      event.currentTarget.focus();
      dragging.current = true;
      at(event);
    },
    onPointerMove(event) {
      if (dragging.current) at(event);
    },
    onPointerUp(event) {
      if (!dragging.current) return;
      dragging.current = false;
      event.currentTarget.releasePointerCapture?.(event.pointerId);
      endEdit();
    },
    onPointerCancel() {
      if (dragging.current) endEdit();
      dragging.current = false;
    },
  };
}

/** Arrow keys as nudges: `move(dx, dy)` in the value's own units, up is +dy. */
function nudges(move, endEdit) {
  return (event) => {
    const step = event.shiftKey ? STEP / 10 : STEP;
    const delta = {
      ArrowLeft: [-step, 0],
      ArrowRight: [step, 0],
      ArrowUp: [0, step],
      ArrowDown: [0, -step],
    }[event.key];
    if (!delta) return;
    event.preventDefault();
    move(...delta);
    endEdit();
  };
}

const clamp1 = (value) => Math.min(Math.max(value, -1), 1);

/**
 * The grade as the Mac app's deck draws it: a band switch, then the band's two-axis colour pad
 * over a wash that says what its axes mean, a gradient capsule for its level, `children` (the
 * Encoded Grade switch), and Reset Grade.
 */
export default function GradeDeck({ children }) {
  const { edit, patch, endEdit, exporting, active } = useEditor();
  const [band, setBand] = useState("Shadows");
  const disabled = exporting || !active;
  const fields = gradeFields(band);
  const params = edit.params;
  const value = {
    warmth: params[fields.warmth] || 0,
    tint: params[fields.tint] || 0,
    level: params[fields.level] || 0,
  };
  const set = (changes) =>
    patch(
      {
        params: {
          ...params,
          ...Object.fromEntries(
            Object.entries(changes).map(([axis, v]) => [fields[axis], v]),
          ),
        },
      },
      `grade-${band}`,
    );
  const padDrag = useDrag((x, y, width, height) => {
    const balance = padBalance(x, y, width, height);
    if (balance) set(balance);
  }, endEdit);
  const levelDrag = useDrag((x, y, width, height) => {
    set({ level: capsuleLevel(x, width, height) });
  }, endEdit);
  const knob = (width, height) => padPoint(value.warmth, value.tint, width, height);
  const reading = gradeReadout(value);
  const bandClass = band.toLowerCase();
  return (
    <div className="grade-deck">
      <SegmentedControl
        aria-label="Grade band"
        UNSAFE_style={{ width: "100%" }}
        selectedKey={band}
        onSelectionChange={setBand}
        isJustified
        isDisabled={disabled}
      >
        {GRADE_BANDS.map((name) => (
          <SegmentedControlItem key={name} id={name}>
            {name}
          </SegmentedControlItem>
        ))}
      </SegmentedControl>
      <div className="grade-caption" role="group" aria-label={`${band} grade`}>
        <span>{band}</span>
        <span className="grade-reading" data-shown={reading ? "" : undefined}>
          {reading}
        </span>
      </div>
      <div
        className={`grade-pad grade-${bandClass}`}
        role="slider"
        aria-roledescription="2D slider"
        aria-label="Color balance pad"
        aria-valuetext={padReading(value.warmth, value.tint)}
        aria-disabled={disabled || undefined}
        tabIndex={disabled ? -1 : 0}
        onKeyDown={nudges(
          (dx, dy) =>
            set({ warmth: clamp1(value.warmth + dx), tint: clamp1(value.tint + dy) }),
          endEdit,
        )}
        {...(disabled ? {} : padDrag)}
      >
        <PadMarks place={knob} />
      </div>
      <div
        className={`grade-level grade-${bandClass}`}
        role="slider"
        aria-label="Level"
        aria-valuemin={-1}
        aria-valuemax={1}
        aria-valuenow={value.level}
        aria-valuetext={levelReading(value.level)}
        aria-disabled={disabled || undefined}
        tabIndex={disabled ? -1 : 0}
        onKeyDown={nudges((dx, dy) => set({ level: clamp1(value.level + dx + dy) }), endEdit)}
        {...(disabled ? {} : levelDrag)}
      >
        <span
          className="grade-level-knob"
          style={{ "--fraction": (value.level + 1) / 2 }}
        />
      </div>
      {children}
      <p className="grade-note">
        Choose Shadows, Midtones, or Highlights. Use the pad to adjust color and the slider to
        adjust brightness. Grade is applied after the film response.
      </p>
      <Button
        size="S"
        variant="negative"
        isDisabled={disabled || gradeIsNeutral(params)}
        onPress={() => {
          patch(
            { params: { ...params, ...Object.fromEntries(GRADE_FIELDS.map((key) => [key, 0])) } },
            "grade-reset",
          );
          endEdit();
        }}
      >
        Reset Grade
      </Button>
    </div>
  );
}

/**
 * What the pad draws over its wash once it has a size: an 11 x 9 dot grid for scale (the axes
 * brighter), a hollow ring at neutral so the way back is visible from anywhere, and the knob.
 */
function PadMarks({ place }) {
  const ref = useRef(null);
  const [size, setSize] = useState(null);
  useLayoutEffect(() => {
    const pad = ref.current?.parentElement;
    if (!pad) return;
    const read = () => setSize({ width: pad.clientWidth, height: pad.clientHeight });
    read();
    const observer = new ResizeObserver(read);
    observer.observe(pad);
    return () => observer.disconnect();
  }, []);
  const inset = 18;
  const dots = [];
  if (size)
    for (let row = 0; row < 9; row++)
      for (let column = 0; column < 11; column++)
        dots.push(
          <circle
            key={`${row}-${column}`}
            cx={inset + (column / 10) * (size.width - inset * 2)}
            cy={inset + (row / 8) * (size.height - inset * 2)}
            r={1.5}
            opacity={column === 5 || row === 4 ? 0.65 : 0.38}
          />,
        );
  const point = size ? place(size.width, size.height) : null;
  return (
    <>
      <svg ref={ref} className="grade-pad-marks" aria-hidden="true">
        {dots}
        {size && (
          <circle
            className="grade-pad-ring"
            cx={size.width / 2}
            cy={size.height / 2}
            r={4.5}
          />
        )}
      </svg>
      {point && <span className="grade-pad-knob" style={{ left: point.x, top: point.y }} />}
    </>
  );
}
