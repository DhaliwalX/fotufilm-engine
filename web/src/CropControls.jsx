import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Text } from "@react-spectrum/s2/Text";
import { Button } from "@react-spectrum/s2/Button";
import { Icon } from "./icons.jsx";
import { Adjustment } from "./Adjustment.jsx";
import { catalogueSlider } from "./editor-catalogue.js";
import {
  fullCrop,
  cropForRatio,
  rotatedCrop,
  flippedCrop,
} from "./editor-state.js";
const aspects = ["free", "original", "1:1", "4:5", "3:2", "16:9"];
export default function CropControls({
  edit,
  width,
  height,
  size,
  disabled,
  patch,
  onEnd,
  onDone,
}) {
  const choices = aspects.includes(edit.ratio)
    ? aspects
    : [...aspects, edit.ratio];
  function aspect(ratio) {
    // Native named aspects follow the orientation; retain older explicit web ratios on load.
    let oriented = ratio;
    if (["4:5", "3:2", "16:9"].includes(ratio)) {
      const [a, b] = ratio.split(":").map(Number);
      oriented =
        height > width
          ? `${Math.min(a, b)}:${Math.max(a, b)}`
          : `${Math.max(a, b)}:${Math.min(a, b)}`;
    }
    onEnd();
    patch({
      ratio,
      cropShape: "rectangle",
      crop: cropForRatio(oriented, width, height),
    });
  }
  const geometry = (field, key = field) => (
    <Adjustment
      slider={catalogueSlider(field, "", 0.1)}
      value={edit[key] || 0}
      onChange={(value) =>
        patch(
          {
            [key]: value,
          },
          key,
        )
      }
      onEnd={onEnd}
      disabled={disabled}
    />
  );
  return (
    <>
      <div className="inspector-title">
        <h2>Crop</h2>
      </div>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Orientation"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <div className="crop-actions">
              <Button
                size="S"
                isDisabled={disabled}
                onPress={() => {
                  onEnd();
                  patch({
                    rotation: (edit.rotation + 1) % 4,
                    ratio: "free",
                    crop:
                      edit.cropShape === "corners"
                        ? rotatedCrop(edit.crop, edit.flip)
                        : fullCrop(),
                  });
                }}
                variant={"secondary"}
              >
                <Icon name="rotate" />
                <Text>{"Rotate Left"}</Text>
              </Button>
              <Button
                size="S"
                isDisabled={disabled}
                onPress={() => {
                  onEnd();
                  patch({
                    flip: !edit.flip,
                    crop:
                      edit.cropShape === "corners"
                        ? flippedCrop(edit.crop)
                        : edit.crop,
                  });
                }}
                variant={"secondary"}
              >
                <Icon name="flip" />
                <Text>{"Flip"}</Text>
              </Button>
            </div>
          </div>
        </DisclosurePanel>
      </Disclosure>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Crop"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <ToggleButton
              size="S"
              isDisabled={disabled}
              onPress={() => {
                onEnd();
                patch({
                  cropShape: "corners",
                  ratio: "free",
                });
              }}
              isSelected={edit.cropShape === "corners"}
            >
              {"Four-Corner Crop"}
            </ToggleButton>
            <Picker
              label="Aspect ratio"
              size="S"
              isDisabled={disabled}
              value={edit.ratio}
              onChange={aspect}
              UNSAFE_style={{
                width: "100%",
              }}
            >
              {choices
                .map((value) => ({
                  value,
                  label:
                    value === "free"
                      ? "Free"
                      : value === "original"
                        ? "Original"
                        : value,
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
            {geometry("straighten")}
            <p className="medium-detail">
              Drag the frame to crop. Four-Corner Crop lets you move each corner
              independently and straightens the selection when you leave Crop.
              Choose an aspect ratio to return to a rectangular crop.
            </p>
            <div className="info-row">
              <span>Crop size</span>
              <span>
                {size.width} × {size.height}
              </span>
            </div>
          </div>
        </DisclosurePanel>
      </Disclosure>
      <Disclosure
        defaultExpanded={true}
        size={"S"}
        isQuiet
        UNSAFE_className={"inspector-section"}
      >
        <DisclosureTitle>{"Perspective"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            {geometry("perspectiveVertical", "perspectiveV")}
            {geometry("perspectiveHorizontal", "perspectiveH")}
            <p className="medium-detail">
              Straighten converging lines caused by camera angle. Strong
              corrections crop more of the image.
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
        <DisclosureTitle>{"Finish"}</DisclosureTitle>
        <DisclosurePanel>
          <div className="control-stack">
            <Button
              size="S"
              isDisabled={disabled}
              UNSAFE_className="full-width"
              onPress={() => {
                onEnd();
                patch({
                  rotation: 0,
                  flip: false,
                  crop: fullCrop(),
                  cropShape: "rectangle",
                  ratio: "free",
                  straighten: 0,
                  perspectiveV: 0,
                  perspectiveH: 0,
                });
              }}
              variant={"secondary"}
            >
              {"Reset Crop"}
            </Button>
            <Button
              size="S"
              UNSAFE_className="full-width"
              isDisabled={disabled}
              onPress={onDone}
              variant={"accent"}
            >
              {"Done"}
            </Button>
          </div>
        </DisclosurePanel>
      </Disclosure>
    </>
  );
}
