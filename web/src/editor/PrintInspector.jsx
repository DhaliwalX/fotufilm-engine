import ProfileFields from "./ProfileFields.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { SCREEN_CONVERSION } from "../generated/controls.js";
import { colorSpaceLabel, preferredCanvasColorSpace } from "../canvas-color.js";
import { profileMedium } from "../profile-settings.js";
import PrintFrameControls from "../PrintFrameControls.jsx";
import { Button } from "@react-spectrum/s2/Button";
import { useEditor } from "./EditorContext.jsx";
export default function PrintInspector() {
  const {
    exporting,
    active,
    edit,
    selectedStock,
    endEdit,
    patch,
    setStage,
    setDifference,
    fixedSettings,
    setDialog,
  } = useEditor();
  return (
    <>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Output"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <Picker
              label="Output medium"
              size="S"
              isDisabled={
                exporting ||
                !active ||
                !edit.stock ||
                edit.halationModel === "layered"
              }
              value={edit.medium || selectedStock?.defaultMedium || "screen"}
              onChange={(medium) => {
                endEdit();
                patch({
                  medium,
                });
                setStage(null);
                setDifference(false);
              }}
              UNSAFE_style={{
                width: "100%",
              }}
            >
              {(
                selectedStock?.media || [
                  {
                    id: "screen",
                    name: "Digital Reference",
                  },
                ]
              )
                .map((medium) => ({
                  value: medium.id,
                  label: medium.name,
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
            {(edit.medium || selectedStock?.defaultMedium) === "screen" &&
              selectedStock?.media.find((m) => m.id === "screen")
                ?.screenConversions && (
                <Picker
                  label={SCREEN_CONVERSION.title}
                  size="S"
                  isDisabled={
                    exporting || !active || edit.halationModel === "layered"
                  }
                  value={edit.digitalReference || SCREEN_CONVERSION.default}
                  onChange={(digitalReference) => {
                    endEdit();
                    patch({
                      digitalReference,
                    });
                    setStage(null);
                    setDifference(false);
                  }}
                  UNSAFE_style={{
                    width: "100%",
                  }}
                >
                  {SCREEN_CONVERSION.choices
                    .map((c) => ({
                      value: c.id,
                      label: c.name,
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
              )}
            {
              <ProfileFields
                fields={[
                  "printLight",
                  "printCorrection",
                  "negativeViewing",
                  "screenGrade",
                  "screenExposure",
                ]}
              />
            }
            {selectedStock && (
              <p className="medium-detail">
                {(edit.medium || selectedStock.defaultMedium) === "screen"
                  ? "Direct display rendering without paper or scanning."
                  : selectedStock.media.find(
                      (m) =>
                        m.id === (edit.medium || selectedStock.defaultMedium),
                    )?.detail}
              </p>
            )}
            <div className="info-row">
              <span>Color space</span>
              <span>{colorSpaceLabel(preferredCanvasColorSpace())}</span>
            </div>
          </div>
        </DisclosurePanel>
      </Disclosure>

      {profileMedium(edit, selectedStock)?.enlarger && (
        <Disclosure
          defaultExpanded={true}
          size={"S"}
          isQuiet
          UNSAFE_className={"inspector-section"}
        >
          <DisclosureTitle>{"Lamp"}</DisclosureTitle>
          <DisclosurePanel>
            <div className="control-stack">
              {
                <ProfileFields
                  fields={[
                    "enlarger",
                    "printerEnabled",
                    "printerLamp",
                    "printerExposure",
                    "printerMagenta",
                    "printerYellow",
                    "printerPreflash",
                  ]}
                />
              }
              <p className="medium-detail">
                {edit.profile?.printerEnabled
                  ? "A simulated tungsten lamp and colour filters expose the paper through the film. More exposure darkens negative paper and lightens positive paper."
                  : "Enable Simulated Printer to adjust lamp temperature, paper exposure and filtration."}
              </p>
            </div>
          </DisclosurePanel>
        </Disclosure>
      )}
      {!fixedSettings && (
        <PrintFrameControls
          edit={edit}
          image={active?.image}
          disabled={exporting || !active}
          onChange={(printFrame) => {
            endEdit();
            patch({
              printFrame,
              ...(["film", "slideMount"].includes(printFrame)
                ? {
                    halationModel: "legacy",
                  }
                : {}),
            });
            setStage(null);
            setDifference(false);
          }}
        />
      )}
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Export"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <Button
              size="S"
              onPress={() => setDialog("export")}
              variant={"secondary"}
            >
              {active?.image.video ? "Export Video…" : "Export Photo…"}
            </Button>
          </div>
        </DisclosurePanel>
      </Disclosure>
    </>
  );
}
