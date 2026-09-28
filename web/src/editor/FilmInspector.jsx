import ProfileFields from "./ProfileFields.jsx";
import { controlDetail, controlHelp } from "./ControlHelp.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import FormatPicker from "./FormatPicker.jsx";
import { hasProfileSettings } from "../profile-settings.js";
import { useEditor } from "./EditorContext.jsx";
export default function FilmInspector() {
  const {
    edit,
    fixedSettings,
    selectedStock,
    exporting,
    active,
    endEdit,
    patch,
    setStage,
    setDifference,
    sceneKelvin,
  } = useEditor();
  return (
    <>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>
          {edit.stock ? "Loaded Film" : "Normal"}
        </DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {fixedSettings && (
              <p className="medium-detail">Fixed profile: film settings are off.</p>
            )}
            <div className="info-row">
              <span>Stock</span>
              <span>{edit.stock ? selectedStock?.name : "None"}</span>
            </div>
          </div>
        </DisclosurePanel>
      </Disclosure>
      {edit.stock && !fixedSettings && (
        <>
          <Disclosure
            defaultExpanded={true}
            size={"S"}
            isQuiet
            UNSAFE_className={"inspector-section"}
          >
            <DisclosureTitle>{"Film Format"}</DisclosureTitle>
            <DisclosurePanel>
              <div className="control-stack">
                <FormatPicker
                  disabled={
                    exporting || !active || edit.halationModel === "layered"
                  }
                  onChange={(format) => {
                    endEdit();
                    patch({ format });
                    setStage(null);
                    setDifference(false);
                  }}
                />
              </div>
            </DisclosurePanel>
          </Disclosure>
          <Disclosure
            defaultExpanded={true}
            size={"S"}
            isQuiet
            UNSAFE_className={"inspector-section"}
          >
            <DisclosureTitle>{"Film Condition"}</DisclosureTitle>
            <DisclosurePanel>
              <div className="control-stack">
                {<ProfileFields fields={["expired"]} />}
              </div>
            </DisclosurePanel>
          </Disclosure>
        </>
      )}
      {edit.stock && (
        <Disclosure
          defaultExpanded={true}
          size={"S"}
          isQuiet
          UNSAFE_className={"inspector-section"}
        >
          <DisclosureTitle>{"Halation"}</DisclosureTitle>
          <DisclosurePanel>
            <div className="control-stack">
              <Picker
                label="Halation Model"
                contextualHelp={controlHelp("Halation Model", controlDetail("halationModel"))}
                size="S"
                value={edit.halationModel || "legacy"}
                onChange={(halationModel) => {
                  endEdit();
                  patch({
                    halationModel,
                    medium: null,
                  });
                  setStage(null);
                  setDifference(false);
                }}
                UNSAFE_style={{
                  width: "100%",
                }}
              >
                {[
                  {
                    value: "legacy",
                    label: "Legacy",
                  },
                  ...(selectedStock?.layeredTransport === false ||
                  sceneKelvin ||
                  hasProfileSettings(edit)
                    ? []
                    : [
                        {
                          value: "layered",
                          label: "Layered Transport",
                        },
                      ]),
                ].map((option) => (
                  <PickerItem
                    id={option.value}
                    key={option.value}
                    isDisabled={option.disabled}
                  >
                    {option.label}
                  </PickerItem>
                ))}
              </Picker>
              {
                <ProfileFields
                  fields={[
                    "halation",
                    "halationReturn",
                    "halationColour",
                    "halationSpectrum",
                    "estimatedHalation",
                  ]}
                />
              }
              {hasProfileSettings(edit) && (
                <p className="medium-detail">
                  Custom film settings use Legacy halation.
                </p>
              )}
              {sceneKelvin && (
                <p className="medium-detail">
                  Custom source illumination uses Legacy halation.
                </p>
              )}
              {edit.halationModel === "layered" && (
                <p className="medium-detail">Uses the film’s defaults.</p>
              )}
            </div>
          </DisclosurePanel>
        </Disclosure>
      )}
    </>
  );
}
