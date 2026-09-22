import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { editorControl } from "./editor-catalogue.js";
export default function SourceInterpretationControls({
  image,
  value,
  disabled,
  onChange,
}) {
  if (
    !image ||
    image.raw ||
    image.video ||
    (image.linear && !image.standardImage)
  )
    return null;
  const control = editorControl("sourceInterpretation");
  return (
    <Disclosure
      defaultExpanded={true}
      size={"S"}
      isQuiet
      UNSAFE_className={"inspector-section"}
    >
      <DisclosureTitle>{"Source Interpretation"}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">
          <Picker
            label={control.title}
            size="S"
            value={value}
            isDisabled={disabled}
            onChange={onChange}
            UNSAFE_style={{
              width: "100%",
            }}
          >
            {control.choices
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
          <p className="medium-detail">
            {control.choices.find((choice) => choice.id === value)?.detail}
          </p>
          {image.hdr && (
            <p className="medium-detail">
              HDR JPEG ·{" "}
              {value === "standardRange"
                ? "Standard rendition"
                : "Full highlight range"}
            </p>
          )}
        </div>
      </DisclosurePanel>
    </Disclosure>
  );
}
