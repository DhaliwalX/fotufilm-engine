import { relatedAssetUrl } from "./runtime-assets.js";
import { decodeHDRPixels, calibrateHDR } from "./hdr-color.js";

self.onmessage = async ({
  data: { bytes, decoderURL, orientation, reference },
}) => {
  let module, input;
  try {
    const factory = (await import(/* @vite-ignore */ decoderURL)).default;
    module = await factory({
      locateFile: (name) => relatedAssetUrl(name, decoderURL),
    });
    input = module._malloc(bytes.byteLength);
    if (!input) throw new Error("Not enough memory to read this HDR photo.");
    module.HEAPU8.set(new Uint8Array(bytes), input);
    const opened = module._hdr_open(input, bytes.byteLength);
    if (opened < 0) throw new Error(module.UTF8ToString(module._hdr_error()));
    if (!opened) {
      self.postMessage({ result: null });
      return;
    }
    self.postMessage({ status: "Decoding HDR highlights" });
    if (!module._hdr_decode())
      throw new Error(module.UTF8ToString(module._hdr_error()));
    const width = module._hdr_width(),
      height = module._hdr_height(),
      stride = module._hdr_stride(),
      pointer = module._hdr_pixels(),
      gamut = module._hdr_gamut();
    if (!pointer || stride < width)
      throw new Error("Invalid HDR decoder output.");
    const half = module.HEAPU16.subarray(
      pointer / 2,
      pointer / 2 + stride * height * 4,
    );
    const result = decodeHDRPixels(
      half,
      width,
      height,
      stride,
      gamut,
      orientation,
    );
    result.referenceGain = calibrateHDR(result, reference);
    self.postMessage({ result }, [result.pixels.buffer]);
  } catch (error) {
    self.postMessage({
      error: error.message || "The HDR decoder could not run.",
    });
  } finally {
    module?._hdr_close();
    if (input) module._free(input);
  }
};
