import { controlHelp } from "./editor/ControlHelp.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { editorControl } from "./editor-catalogue.js";
import { usePrintFrame } from "./usePrintFrame.js";
export default function PrintFrameControls({
  edit,
  image,
  disabled,
  onChange,
}) {
  const { plan, pending, error } = usePrintFrame(
    edit,
    1,
    1,
    !!image && !image.video,
  );
  if (!image || image.video) return null;
  const control = editorControl("printFrame");
  const value = edit.printFrame || "none";
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
