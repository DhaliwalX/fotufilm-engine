import AdjustmentGroup from "./AdjustmentGroup.jsx";
import { WithHelp, controlDetail, controlHelp } from "./ControlHelp.jsx";
import GradeDeck from "./GradeDeck.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Switch } from "@react-spectrum/s2/Switch";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { editorControl } from "../editor-catalogue.js";
import { useEditor } from "./EditorContext.jsx";
export default function LightInspector() {
  const { edit, patch, exporting, active, endEdit } = useEditor();
  return (
    <>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Light"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {<AdjustmentGroup group={"Light"} />}
            <WithHelp label="Regional" detail={controlDetail("localTone")}>
              <Switch
                isSelected={edit.localTone}
                onChange={(value) =>
                  patch({
                    localTone: value,
                  })
                }
                isDisabled={exporting || !active}
                size="S"
              >
                {"Regional"}
              </Switch>
            </WithHelp>
          </div>
        </DisclosurePanel>
      </Disclosure>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Source Illuminant"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <Picker
              label={editorControl("sceneLight").title}
              contextualHelp={controlHelp(
                editorControl("sceneLight").title,
                controlDetail("sceneLight"),
              )}
              size="S"
              value={edit.sceneLight}
              onChange={(sceneLight) => {
                endEdit();
                patch({
                  sceneLight,
                  ...(sceneLight !== "unspecified"
                    ? {
                        halationModel: "legacy",
                      }
                    : {}),
                });
              }}
              UNSAFE_style={{
                width: "100%",
              }}
            >
              {editorControl("sceneLight")
                .choices.map((c) => ({
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
            {edit.sceneLight === "custom" && (
              <AdjustmentGroup group={"Source Illuminant"} />
            )}
            <p className="medium-detail">
              {editorControl("sceneLight").detail}
            </p>
          </div>
        </DisclosurePanel>
      </Disclosure>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"White Balance"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {<AdjustmentGroup group={"White Balance"} />}
          </div>
        </DisclosurePanel>
      </Disclosure>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Color"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {<AdjustmentGroup group={"Color"} />}
          </div>
        </DisclosurePanel>
      </Disclosure>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Grade"}</DisclosureTitle>
        <DisclosurePanel>
          <GradeDeck>
            <WithHelp label="Encoded Grade" detail={controlDetail("gradeSpace")}>
              <Switch
                isSelected={edit.gradeSpace}
                onChange={(value) =>
                  patch({
                    gradeSpace: value,
                  })
                }
                isDisabled={exporting || !active}
                size="S"
              >
                {"Encoded Grade"}
              </Switch>
            </WithHelp>
          </GradeDeck>
        </DisclosurePanel>
      </Disclosure>
    </>
  );
}
