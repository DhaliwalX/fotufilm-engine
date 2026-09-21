import { Selector } from "@astryxdesign/core/Selector";
import { Section } from "./EditorControls.jsx";
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
    <Section title="Source Interpretation">
      <Selector
        label={control.title}
        size="sm"
        width="100%"
        value={value}
        isDisabled={disabled}
        options={control.choices.map((choice) => ({
          value: choice.id,
          label: choice.label,
        }))}
        onChange={onChange}
      />
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
    </Section>
  );
}
