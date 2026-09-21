import { relatedAssetUrl } from "./runtime-assets.js";
import { orientedPixel } from "./hdr-color.js";

self.onmessage = async ({
  data: { bytes, decoderURL, linearSamples = false },
}) => {
  let module, input;
  try {
    const factory = (await import(/* @vite-ignore */ decoderURL)).default;
    module = await factory({
      locateFile: (name) => relatedAssetUrl(name, decoderURL),
    });
    input = module._malloc(bytes.byteLength);
    if (!input) throw new Error("Not enough memory to read this TIFF.");
    module.HEAPU8.set(new Uint8Array(bytes), input);
    const failure = () =>
      new Error(
        module.UTF8ToString(module._tiff_decoder_error()) ||
          "TIFF decoding failed.",
      );
    self.postMessage({ status: "Reading TIFF color profile" });
    if (!module._tiff_decoder_open(input, bytes.byteLength, +linearSamples))
      throw failure();
    const sourceWidth = module._tiff_decoder_width(),
      sourceHeight = module._tiff_decoder_height(),
      orientation = module._tiff_decoder_orientation(),
      bitDepth = module._tiff_decoder_depth(),
      swapped = orientation >= 5 && orientation <= 8,
      width = swapped ? sourceHeight : sourceWidth,
      height = swapped ? sourceWidth : sourceHeight,
      pixels = new Float32Array(width * height * 4),
      blocks = module._tiff_decoder_blocks();
    for (let block = 0; block < blocks; block++) {
      if (!module._tiff_decoder_block(block)) throw failure();
      const left = module._tiff_decoder_x(),
        top = module._tiff_decoder_y(),
        bw = module._tiff_decoder_block_width(),
        bh = module._tiff_decoder_block_height(),
        capacity = module._tiff_decoder_capacity();
      for (let row = 0; row < bh; row += capacity) {
        const count = Math.min(capacity, bh - row),
          pointer = module._tiff_decoder_rows(row, count);
        if (!pointer) throw failure();
        const data = module.HEAPF32.subarray(
          pointer / 4,
          pointer / 4 + bw * count * 4,
        );
        for (let y = 0; y < count; y++)
          for (let x = 0; x < bw; x++) {
            const [ox, oy] = orientedPixel(
              left + x,
              top + row + y,
              sourceWidth,
              sourceHeight,
              orientation,
            );
            const from = (y * bw + x) * 4,
              to = (oy * width + ox) * 4,
              alpha = data[from + 3];
            for (let c = 0; c < 3; c++) {
              if (!Number.isFinite(data[from + c]))
                throw new Error(
                  "TIFF color conversion produced an invalid sample.",
                );
              pixels[to + c] = data[from + c] * alpha;
            }
            pixels[to + 3] = 1;
          }
        self.postMessage({
          status: `Decoding TIFF samples · ${Math.round((100 * (block + (row + count) / bh)) / blocks)}%`,
        });
      }
    }
    self.postMessage({ result: { pixels, width, height, bitDepth } }, [
      pixels.buffer,
    ]);
  } catch (error) {
    self.postMessage({
      error: error.message || "The TIFF decoder could not run.",
    });
  } finally {
    module?._tiff_decoder_close();
    if (input) module._free(input);
  }
};
