// Version the JavaScript-facing host contract independently of native transport or kernel ABI.
export const BACKEND_VERSION = 1;
export const BACKEND_METHODS = Object.freeze([
  "createSession",
  "prepare",
  "loadStocks",
  "importMedia",
  "releaseImage",
  "analyseNegative",
  "convertNegative",
  "makePreview",
  "createHistogram",
  "autoAdjust",
  "planPrintFrame",
  "resolveLensPlan",
  "outputColorSpace",
  "sampleScene",
  "exportImage",
  "exportVideo",
]);
export const LENS_METHODS = Object.freeze([
  "snapshot",
  "subscribe",
  "load",
  "import",
  "remove",
]);

export function requireMethods(value, methods, label) {
  for (const method of methods)
    if (typeof value?.[method] !== "function")
      throw new Error(`${label} is missing ${method}().`);
  return value;
}
export function validateBackend(backend) {
  if (backend?.version !== BACKEND_VERSION)
    throw new Error(
      "The image backend uses an incompatible interface version.",
    );
  requireMethods(backend, BACKEND_METHODS, "Image backend");
  requireMethods(backend.lenses, LENS_METHODS, "Lens catalogue");
  return backend;
}
