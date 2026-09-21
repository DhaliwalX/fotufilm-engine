// Scene-linear Rec.2020 storage, shared by floating-point image importers.
// The optional standard rendition is display-referred and stays separate.
export class LinearImage {
  #pixels;
  constructor({ pixels, width, height }, standardImage = null) {
    this.naturalWidth = width;
    this.naturalHeight = height;
    this.#pixels = { data: pixels, colors: 4 };
    this.standardImage = standardImage;
  }
  get linear() {
    return this.#pixels;
  }
}
