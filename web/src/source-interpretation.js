import { editorControl } from "./editor-catalogue.js";

export function parseSourceInterpretation(value = "automatic") {
  if (
    !editorControl("sourceInterpretation").choices.some(
      (choice) => choice.id === value,
    )
  )
    throw new Error("Invalid source interpretation.");
  return value;
}

export function interpretedImage(image, interpretation) {
  // RAW stays scene-linear. A processed photo uses the independently decoded
  // platform rendition only when Standard Range is explicitly selected.
  return !image.raw && interpretation === "standardRange" && image.standardImage
    ? image.standardImage
    : image;
}
