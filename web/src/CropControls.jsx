import { Button } from "@astryxdesign/core/Button";
import { Selector } from "@astryxdesign/core/Selector";
import { Adjustment, Icon, Section } from "./EditorControls.jsx";
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
      onChange={(value) => patch({ [key]: value }, key)}
      onEnd={onEnd}
      disabled={disabled}
    />
  );
  return (
    <>
      <div className="inspector-title">
        <h2>Crop</h2>
      </div>
      <Section title="Orientation">
        <div className="crop-actions">
          <Button
            label="Rotate Left"
            variant="secondary"
            size="sm"
            isDisabled={disabled}
            icon={<Icon name="rotate" />}
            onClick={() => {
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
          />
          <Button
            label="Flip"
            variant="secondary"
            size="sm"
            isDisabled={disabled}
            icon={<Icon name="flip" />}
            onClick={() => {
              onEnd();
              patch({
                flip: !edit.flip,
                crop:
                  edit.cropShape === "corners"
                    ? flippedCrop(edit.crop)
                    : edit.crop,
              });
            }}
          />
        </div>
      </Section>
      <Section title="Crop">
        <Button
          label="Four-Corner Crop"
          variant="secondary"
          size="sm"
          isDisabled={disabled}
          aria-pressed={edit.cropShape === "corners"}
          onClick={() => {
            onEnd();
            patch({ cropShape: "corners", ratio: "free" });
          }}
        />
        <Selector
          label="Aspect ratio"
          size="sm"
          width="100%"
          isDisabled={disabled}
          value={edit.ratio}
          options={choices.map((value) => ({
            value,
            label:
              value === "free"
                ? "Free"
                : value === "original"
                  ? "Original"
                  : value,
          }))}
          onChange={aspect}
        />
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
      </Section>
      <Section title="Perspective">
        {geometry("perspectiveVertical", "perspectiveV")}
        {geometry("perspectiveHorizontal", "perspectiveH")}
        <p className="medium-detail">
          Straighten converging lines caused by camera angle. Strong corrections
          crop more of the image.
        </p>
      </Section>
      <Section title="Finish">
        <Button
          label="Reset Crop"
          variant="secondary"
          size="sm"
          isDisabled={disabled}
          className="full-width"
          onClick={() => {
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
        />
        <Button
          label="Done"
          variant="primary"
          size="sm"
          className="full-width"
          isDisabled={disabled}
          onClick={onDone}
        />
      </Section>
    </>
  );
}
