import { Switch } from "@astryxdesign/core/Switch";
import { Button } from "@astryxdesign/core/Button";
import { Adjustment, Section } from "./EditorControls.jsx";
import { catalogueSlider, editorControl } from "./editor-catalogue.js";
import {
  defaultLens,
  hasLensAdjustments,
  lensFields,
} from "./lens-correction.js";
import "./motion.css";
import "./LensControls.css";

export default function LensControls({
  lens = defaultLens(),
  disabled,
  onChange,
  onEnd,
}) {
  const set = (key, value) =>
    onChange({ ...lens, [key]: value }, `lens:${key}`);
  return (
    <Section title="Lens">
      <Switch
        label={editorControl("lensCorrection").title}
        value={lens.enabled}
        isDisabled={disabled}
        onChange={(enabled) => {
          onEnd();
          onChange({ ...lens, enabled });
          onEnd();
        }}
      />
      {lens.enabled && (
        <div className="motion-panel-enter lens-adjustments">
          <p className="medium-detail">
            Adjust the lens by hand. Camera and measured lens profiles are not
            yet available in the browser.
          </p>
          {Object.entries(lensFields).map(([field, key]) => (
            <Adjustment
              key={key}
              slider={catalogueSlider(field, "Lens")}
              value={lens[key]}
              disabled={disabled}
              onChange={(value) => set(key, value)}
              onEnd={onEnd}
            />
          ))}
          <Button
            label="Reset Lens"
            size="sm"
            variant="ghost"
            isDisabled={disabled || !hasLensAdjustments(lens)}
            onClick={() => {
              onEnd();
              onChange({ ...defaultLens(), enabled: lens.enabled });
              onEnd();
            }}
          />
        </div>
      )}
    </Section>
  );
}
