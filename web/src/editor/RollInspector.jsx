import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { ProgressBar } from "@react-spectrum/s2/ProgressBar";
import { useEditor } from "./EditorContext.jsx";

function Section({ title, children }) {
  return (
    <Disclosure
      defaultExpanded={true}
      size={"S"}
      isQuiet
      UNSAFE_className={"inspector-section"}
    >
      <DisclosureTitle>{title}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">{children}</div>
      </DisclosurePanel>
    </Disclosure>
  );
}

// A scanned negative's Roll panel: what the frames of its roll share (useRollActions). The roll is
// the strip's negatives from the frame's folder; its colour balance is measured on all of them and
// kept with each, every frame still timed on its own highlights.
export default function RollInspector() {
  const {
    edit,
    active,
    exporting,
    rollFrames,
    rollMeasuring,
    measureRoll,
    cancelRollMeasure,
    clearRoll,
    unrollFrame,
  } = useEditor();
  const negative = edit.negative;
  if (!negative) return null;
  const roll = negative.roll;
  const disabled = exporting || !active || !!rollMeasuring;
  const enough = rollFrames.length >= 2;
  return (
    <>
      <Section title="Roll">
        <div className="info-row">
          <span>Frames</span>
          <span>{rollFrames.length || "Not in a folder"}</span>
        </div>
      </Section>
      <Section title="Colour Balance">
        <div className="info-row">
          <span>Balanced on</span>
          <span>{roll ? `Roll of ${roll.frames} frames` : "This frame"}</span>
        </div>
        {rollMeasuring ? (
          <>
            <ProgressBar
              size="S"
              label={`Measuring frame ${Math.min(rollMeasuring.done + 1, rollMeasuring.total)} of ${rollMeasuring.total}`}
              value={(100 * rollMeasuring.done) / rollMeasuring.total}
              UNSAFE_style={{ width: "100%" }}
            />
            <ActionButton size="S" onPress={cancelRollMeasure}>
              Cancel
            </ActionButton>
          </>
        ) : (
          <ActionButton
            size="S"
            isDisabled={disabled || !enough}
            onPress={measureRoll}
          >
            {roll ? "Measure Roll Again" : "Measure Roll"}
          </ActionButton>
        )}
        <ActionButton
          size="S"
          isDisabled={disabled || !roll}
          onPress={unrollFrame}
        >
          Balance This Frame Alone
        </ActionButton>
        <ActionButton
          size="S"
          isDisabled={disabled || !enough}
          onPress={clearRoll}
        >
          Balance Every Frame Alone
        </ActionButton>
        <p className="inspector-hint">
          {enough
            ? "Frames shot on one roll under one light share the colour of the roll's highlights. Each frame keeps its own exposure. Measure again after cropping or adding frames."
            : "Open a frame from a library folder of negatives: its roll is every negative in that folder."}
        </p>
      </Section>
    </>
  );
}
