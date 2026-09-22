import ProfileFields from "./ProfileFields.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { FILM_FORMATS } from "../generated/controls.js";
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
              <p className="medium-detail">
                This film uses a fixed profile. Exposure, grading, crop, output
                media and export remain available. Film customisation, optical
                filters, Auto Adjust and print frames are unavailable.
              </p>
            )}
            {edit.stock ? (
              <>
                <div className="info-row">
                  <span>Stock</span>
                  <span>{selectedStock?.name}</span>
                </div>
                <p className="medium-detail">
                  Choose a stock from the film library on the left.
                </p>
              </>
            ) : (
              <p className="medium-detail">
                Film simulation is off. Choose a film from the library. With
                Normal selected, use Expose to adjust the source and Print to
                finish the image.
              </p>
            )}
            <p className="medium-detail">
              Click and hold the photo to compare with the original.
            </p>
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
                <Picker
                  label="Format"
                  size="S"
                  isDisabled={
                    exporting || !active || edit.halationModel === "layered"
                  }
                  value={edit.format || "film"}
                  onChange={(format) => {
                    endEdit();
                    patch({
                      format: format === "film" ? null : format,
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
                      value: "film",
                      label: "Match Film",
                    },
                    ...FILM_FORMATS.map((f) => ({
                      value: f.id,
                      label: f.name,
                    })),
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
                <p className="medium-detail">
                  Uses the film’s default format, condition, grain model and
                  output medium. Choose Legacy to adjust these settings.
                  Pipeline inspection is available with Legacy.
                </p>
              )}
            </div>
          </DisclosurePanel>
        </Disclosure>
      )}
    </>
  );
}
