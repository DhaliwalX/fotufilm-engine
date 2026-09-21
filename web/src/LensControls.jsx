import { useEffect, useState } from "react";
import { Switch } from "@astryxdesign/core/Switch";
import { Button } from "@astryxdesign/core/Button";
import { Selector } from "@astryxdesign/core/Selector";
import { Adjustment, Section } from "./EditorControls.jsx";
import { catalogueSlider, editorControl } from "./editor-catalogue.js";
import {
  defaultLens,
  hasLensAdjustments,
  lensFields,
} from "./lens-correction.js";
import LensProfileLibrary from "./LensProfileLibrary.jsx";
import { resolveLensPlan } from "./lens-plan.js";
import { useLensCatalogue } from "./useLensCatalogue.js";
import "./motion.css";
import "./LensControls.css";

export default function LensControls({
  image,
  lens = defaultLens(),
  disabled,
  onChange,
  onEnd,
}) {
  const catalogue = useLensCatalogue();
  const [plan, setPlan] = useState(null),
    [error, setError] = useState(null);
  const settings = JSON.stringify({
    enabled: lens.enabled,
    profileID: lens.profileID,
  });
  useEffect(() => {
    let cancelled = false;
    setPlan(null);
    setError(null);
    if (image && lens.enabled) {
      resolveLensPlan(image, { ...defaultLens(), ...JSON.parse(settings) })
        .then((result) => {
          if (!cancelled) setPlan(result);
        })
        .catch((error) => {
          if (!cancelled) setError(error.message);
        });
    }
    return () => {
      cancelled = true;
    };
  }, [image, settings, catalogue.revision]);
  const set = (key, value) =>
    onChange({ ...lens, [key]: value }, `lens:${key}`);
  const amount = catalogueSlider("lensAmount", "Lens");
  const choose = (profileID) => {
    onEnd();
    onChange({ ...lens, profileID });
    onEnd();
  };
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
          {!!catalogue.profiles.length && (
            <Selector
              label="Profile"
              size="sm"
              width="100%"
              value={lens.profileID ? `profile:${lens.profileID}` : "automatic"}
              isDisabled={disabled}
              options={[
                { value: "automatic", label: "Automatic" },
                ...catalogue.profiles.map((profile) => ({
                  value: `profile:${profile.id}`,
                  label: `${profile.maker} ${profile.model}`,
                })),
                ...(lens.profileID &&
                !catalogue.profiles.some(
                  (profile) => profile.id === lens.profileID,
                )
                  ? [
                      {
                        value: `profile:${lens.profileID}`,
                        label: "Profile not installed",
                      },
                    ]
                  : []),
              ]}
              onChange={(id) =>
                choose(id === "automatic" ? null : id.slice("profile:".length))
              }
            />
          )}
          <p className="medium-detail lens-plan-note" role="status">
            {plan?.note ||
              (error
                ? "Lens correction could not be prepared."
                : "Reading lens correction…")}
          </p>
          {plan && plan.measurement !== "none" && (
            <Adjustment
              slider={{
                ...amount,
                min: amount.min * 100,
                max: amount.max * 100,
                def: amount.def * 100,
                step: 1,
                unit: "%",
              }}
              value={(lens.amount ?? 1) * 100}
              disabled={disabled}
              onChange={(value) => set("amount", value / 100)}
              onEnd={onEnd}
            />
          )}
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
          <LensProfileLibrary disabled={disabled} />
          {error && (
            <p className="medium-detail" role="alert">
              {error}
            </p>
          )}
        </div>
      )}
    </Section>
  );
}
