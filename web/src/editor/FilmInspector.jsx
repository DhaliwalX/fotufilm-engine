import ProfileFields from "./ProfileFields.jsx";
import { controlDetail, controlHelp } from "./ControlHelp.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import FormatPicker from "./FormatPicker.jsx";
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
    backend,
  } = useEditor();
  // The native engine solves Layered Transport for every film. The browser's packs carry three
  // records, so a donor stock's fourth layer keeps it on Legacy there.
  const native = backend?.kind === "native";
  const layeredOffered = native || selectedStock?.layeredTransport !== false;
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
                  disabled={exporting || !active}
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
                  patch({ halationModel });
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
                  ...(layeredOffered
                    ? [
                        {
                          value: "layered",
                          label: "Layered Transport",
                        },
                      ]
                    : []),
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
                    "halationHaze",
                    "antiHalation",
                    "baseThickness",
                    "pressurePlate",
                    "estimatedHalation",
                  ]}
                />
              }
            </div>
          </DisclosurePanel>
        </Disclosure>
      )}
    </>
  );
}
