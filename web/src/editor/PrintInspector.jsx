import ProfileFields from "./ProfileFields.jsx";
import { controlDetail, controlHelp } from "./ControlHelp.jsx";
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

// The Output Medium choice that follows the film, as the Mac app's does.
const MATCH_FILM = "match-film";

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
  // A film that is its own print (instax) has only its own medium to match.
  const canMatchFilm = !!selectedStock?.filmMedium && !selectedStock.reflectionPrint;
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
              value={
                edit.mediumFollowsFilm && canMatchFilm
                  ? MATCH_FILM
                  : edit.medium || selectedStock?.defaultMedium || "screen"
              }
              onChange={(choice) => {
                endEdit();
                // Match Film prints on the film's own medium, and on each next film's own.
                patch(
                  choice === MATCH_FILM
                    ? { medium: selectedStock.filmMedium, mediumFollowsFilm: true }
                    : { medium: choice, mediumFollowsFilm: false },
                );
                setStage(null);
                setDifference(false);
              }}
              UNSAFE_style={{
                width: "100%",
              }}
            >
              {[
                ...(canMatchFilm ? [{ id: MATCH_FILM, name: "Match Film" }] : []),
                ...(selectedStock?.media || [
                  {
                    id: "screen",
                    name: "Digital Reference",
                  },
                ]),
              ]
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
                  contextualHelp={controlHelp(
                    SCREEN_CONVERSION.title,
                    controlDetail("digitalReference"),
                  )}
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
                  "paperColor",
                  "printLight",
                  "printCorrection",
                  "negativeViewing",
                  "screenGrade",
                  "screenExposure",
                ]}
              />
            }
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
