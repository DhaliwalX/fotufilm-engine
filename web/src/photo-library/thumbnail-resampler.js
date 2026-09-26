// JavaScript side of the Halide thumbnail resampler (web/engine/library_wasm.cpp).

// The thumbnail's shape after orientation, its long edge at most `edge`.
export function thumbnailSize(width, height, edge, orientation = 1) {
  const scale = Math.min(1, edge / Math.max(width, height));
  const w = Math.max(1, Math.round(width * scale)),
    h = Math.max(1, Math.round(height * scale));
  return orientation >= 5 ? [h, w] : [w, h];
}

// One module per worker; its heap buffers grow to the largest request seen.
export function createResampler(module) {
  let input = 0,
    inputBytes = 0,
    output = 0,
    outputBytes = 0;
  const reserve = (pointer, bytes, needed) => {
    if (bytes >= needed) return [pointer, bytes];
    if (pointer) module._free(pointer);
    const next = module._malloc(needed);
    if (!next) throw new Error("Not enough memory for a thumbnail.");
    return [next, needed];
  };
  return function resample(pixels, width, height, edge, orientation = 1) {
    const [outWidth, outHeight] = thumbnailSize(
      width,
      height,
      edge,
      orientation,
    );
    [input, inputBytes] = reserve(input, inputBytes, pixels.length);
    [output, outputBytes] = reserve(
      output,
      outputBytes,
      outWidth * outHeight * 4,
    );
    module.HEAPU8.set(pixels, input);
    const code = module._library_thumbnail_rgba(
      input,
      width,
      height,
      output,
      outWidth,
      outHeight,
      orientation,
    );
    if (code) throw new Error(`Thumbnail resampling failed (${code}).`);
    return {
      width: outWidth,
      height: outHeight,
      pixels: new Uint8ClampedArray(
        module.HEAPU8.slice(output, output + outWidth * outHeight * 4).buffer,
      ),
    };
  };
}
