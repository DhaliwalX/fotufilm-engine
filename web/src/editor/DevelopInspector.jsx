import AdjustmentGroup from "./AdjustmentGroup.jsx";
import ProfileFields from "./ProfileFields.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Button } from "@react-spectrum/s2/Button";
import { useEditor } from "./EditorContext.jsx";
export default function DevelopInspector() {
  const { edit, fixedSettings, patch, selectedStock } = useEditor();
  return edit.stock ? (
    <>
      {!fixedSettings && (
        <Disclosure
          defaultExpanded={true}
          size={"S"}
          isQuiet
          UNSAFE_className={"inspector-section"}
        >
          <DisclosureTitle>{"Development"}</DisclosureTitle>
          <DisclosurePanel>
            <div className="control-stack">
              {<ProfileFields fields={["push", "bleach"]} />}
              <p className="medium-detail">
                Push and pull are available only when the film has measured
                settings. Bleach bypass retains silver in the negative.
              </p>
            </div>
          </DisclosurePanel>
        </Disclosure>
      )}
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Grain"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {<AdjustmentGroup group={"Character"} />}
            {<ProfileFields fields={["grainMottle", "grainModel"]} />}
            <Button
              size="S"
              UNSAFE_className="secondary full-width"
              onPress={() =>
                patch({
                  seed: crypto.getRandomValues(new Uint32Array(1))[0],
                })
              }
              variant={"secondary"}
            >
              {"New Grain Pattern"}
            </Button>
          </div>
        </DisclosurePanel>
      </Disclosure>
      {selectedStock?.available.some((field) =>
        [
          "couplers",
          "couplerReach",
          "couplerSelf",
          "chromaticFringeAmount",
        ].includes(field),
      ) && (
        <Disclosure
          defaultExpanded={true}
          size={"S"}
          isQuiet
          UNSAFE_className={"inspector-section"}
        >
          <DisclosureTitle>{"Colour Separation"}</DisclosureTitle>
          <DisclosurePanel>
            <div className="control-stack">
              {
                <ProfileFields
                  fields={[
                    "couplers",
                    "couplerReach",
                    "couplerSelf",
                    "chromaticFringeAmount",
                    "chromaticFringeRadius",
                  ]}
                />
              }
            </div>
          </DisclosurePanel>
        </Disclosure>
      )}
    </>
  ) : (
    <Disclosure
      defaultExpanded={true}
      size={"S"}
      isQuiet
      UNSAFE_className={"inspector-section"}
    >
      <DisclosureTitle>{"Normal"}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">
          <p>Choose a film from the library to use development and grain.</p>
        </div>
      </DisclosurePanel>
    </Disclosure>
  );
}
