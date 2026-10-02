// Scene-linear Rec.2020 storage, shared by floating-point image importers.
export class LinearImage {
  #pixels;
  constructor({ pixels, width, height }) {
    this.naturalWidth = width;
    this.naturalHeight = height;
    this.#pixels = { data: pixels, colors: 4 };
  }
  get linear() {
    return this.#pixels;
  }
}
