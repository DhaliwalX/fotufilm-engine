import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Switch } from "@react-spectrum/s2/Switch";
import { Button } from "@react-spectrum/s2/Button";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { SELECTION } from "./generated/controls.js";
import { SLIDERS } from "./editor-state.js";
import { newSelection, selectionDevelop, selectionKeys } from "./selective.js";
import { Adjustment } from "./Adjustment.jsx";
import { useBackend } from "./backend/BackendContext.jsx";
export default function SelectiveControls({
  edit,
  patch,
  endEdit,
  sampling,
  setSampling,
  showMask,
  setShowMask,
  canSample,
  disabled,
  subjects,
}) {
  const backend = useBackend();
  const selection = edit.selective || newSelection(edit);
  // Subjects come from the native host's detector; the browser selects by colour and light.
  const choices = SELECTION.choices.filter(
    (option) => !option.native || backend.subjectSelection,
  );
  const subject = selection.kind === "subject";
  // A subject selection's rim, or a colour or light selection's reach.
  const sliders = subject ? SELECTION.subjectSliders : SELECTION.sliders;
  const [finding, none, one, many] = SELECTION.subjectsFound;
  const found =
    subjects == null
      ? finding
      : subjects === 0
        ? none
        : subjects === 1
          ? one
          : many.replace("%d", subjects);
  const change = (value, group) =>
    patch(
      {
        selective: {
          ...selection,
          ...value,
        },
      },
      group,
    );
  return (
    <>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{SELECTION.section}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <Picker
              label={SELECTION.kind}
              value={selection.kind}
              size="S"
              isDisabled={disabled}
              onChange={(kind) =>
                change({
                  kind,
                })
              }
              UNSAFE_style={{
                width: "100%",
              }}
            >
              {choices.map((option) => (
                <PickerItem
                  id={option.value}
                  key={option.value}
                  isDisabled={option.disabled}
                >
                  {option.label}
                </PickerItem>
              ))}
            </Picker>
            <Button
              size="S"
              isDisabled={disabled || !canSample}
              onPress={() => setSampling(!sampling)}
              variant={"secondary"}
            >
              {sampling ? SELECTION.sampling : SELECTION.sample}
            </Button>
            {subject && (
              <p className="medium-detail" role="status">
                {found}
              </p>
            )}
            {sliders.map((slider) => (
              <Adjustment
                key={slider.key}
                disabled={disabled}
                slider={slider}
                value={selection[slider.key] ?? slider.def}
                onChange={(value) =>
                  change(
                    {
                      [slider.key]: value,
                    },
                    `selective-${slider.key}`,
                  )
                }
                onEnd={endEdit}
              />
            ))}
            <Switch
              isSelected={showMask}
              isDisabled={disabled || (!subject && !selection.sample)}
              size="S"
              onChange={setShowMask}
            >
              {SELECTION.mask}
            </Switch>
            <Button
              size="S"
              isDisabled={disabled || !edit.selective}
              onPress={() => {
                patch({
                  selective: null,
                });
                setSampling(false);
                setShowMask(false);
              }}
              variant={"secondary"}
            >
              {SELECTION.clear}
            </Button>
            <p className="medium-detail">
              {selection.kind === "subject"
                ? "Click a subject in the photo to select it, or the background to select every subject, then adjust the selection."
                : "Sample the photo to select similar colors or brightness, then adjust the selection."}
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
        <DisclosureTitle>{"Selection Light"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {SLIDERS.filter(
              (s) =>
                selectionKeys.includes(s.key) && !s.key.startsWith("grade"),
            ).map((slider) => (
              <Adjustment
                key={slider.key}
                disabled={disabled}
                slider={slider}
                value={selection.params[slider.key]}
                onChange={(value) =>
                  change(
                    {
                      params: {
                        ...selection.params,
                        [slider.key]: value,
                      },
                    },
                    `selective-${slider.key}`,
                  )
                }
                onEnd={endEdit}
              />
            ))}
            <Switch
              isSelected={selection.localTone}
              isDisabled={disabled}
              size="S"
              onChange={(localTone) =>
                change({
                  localTone,
                })
              }
            >
              {"Regional"}
            </Switch>
            <Button
              isDisabled={disabled}
              size="S"
              onPress={() => change(selectionDevelop(edit))}
              variant={"secondary"}
            >
              {SELECTION.match}
            </Button>
          </div>
        </DisclosurePanel>
      </Disclosure>
    </>
  );
}
