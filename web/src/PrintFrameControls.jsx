import { controlHelp } from "./editor/ControlHelp.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { Adjustment } from "./Adjustment.jsx";
import { catalogueSlider, editorControl } from "./editor-catalogue.js";
import { usePrintFrame } from "./usePrintFrame.js";
export default function PrintFrameControls({
  edit,
  image,
  disabled,
  onChange,
  onMarginChange,
  onEnd,
}) {
  // The choices a frame offers do not depend on its width, so dragging Border Width neither
  // re-plans them nor holds the menu while it does.
  const { plan, pending, error } = usePrintFrame(
    { ...edit, printFrameMargin: 1 },
    1,
    1,
    !!image && !image.video,
  );
  if (!image || image.video) return null;
  const control = editorControl("printFrame");
  const value = edit.printFrame || "none";
  // Shown as a percentage of the frame's preset margin, as Lens Amount is.
  const margin = catalogueSlider("printFrameMargin", "Frame", 0.01);
  return (
    <Disclosure
      defaultExpanded={true}
      size={"S"}
      isQuiet
      UNSAFE_className={"inspector-section"}
    >
      <DisclosureTitle>{"Frame"}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">
          <Picker
            label={control.title}
            contextualHelp={controlHelp(control.title, control.detail)}
            size="S"
            value={value}
            isDisabled={disabled || pending || !!error}
            onChange={onChange}
            UNSAFE_style={{
              width: "100%",
            }}
          >
            {control.choices
              .filter((c) => c.id === value || plan?.available.includes(c.id))
              .map((c) => ({
                value: c.id,
                label: c.label,
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
          {plan?.configuration.frame === value && plan.configuration.margin != null && (
            <Adjustment
              slider={{
                ...margin,
                min: margin.min * 100,
                max: margin.max * 100,
                def: margin.def * 100,
                step: 1,
                unit: "%",
              }}
              value={(edit.printFrameMargin ?? 1) * 100}
              disabled={disabled}
              onChange={(next) => onMarginChange(next / 100)}
              onEnd={onEnd}
            />
          )}
          {(error || pending) && (
            <p className="medium-detail" role={error ? "alert" : "status"}>
              {error || "Loading frame options…"}
            </p>
          )}
          {plan && plan.configuration.frame !== value && (
            <p className="medium-detail">Shown once the film and medium support it.</p>
          )}
          {plan?.renderMedium && (
            <p className="medium-detail">
              {plan.renderMedium === "negative" ? "Viewed on a light box." : "Viewed by transmission."}
            </p>
          )}
        </div>
      </DisclosurePanel>
    </Disclosure>
  );
}
