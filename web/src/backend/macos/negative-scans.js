import { fileBase64, imageBlob, importedImage } from "./transport.js";

// The negative-scan session's calls (Sources/FotufilmHost/HostService+NegativeScan.swift): a
// scan opens once under a handle, and every preview, border sample and the imported positive is
// a print of it to the page's recipe (NegativeScanRecipe). `binary` hosts send file bytes beside
// the message; WebKit's sends base64.
export function createNegativeScans(call, { binary, encoding }) {
  async function withFile(file, params, options) {
    if (file.path) return call(options.method, { ...params, path: file.path }, options);
    if (binary)
      return call(options.method, { ...params, name: file.name }, {
        ...options,
        payload: await file.arrayBuffer(),
      });
    return call(options.method, {
      ...params,
      name: file.name,
      data: await fileBase64(file),
    }, options);
  }
  return Object.freeze({
    // Whether a scan's samples may be read as linear light instead of through its profile.
    encoding: encoding === true,
    open: (file, { linearSamples = false, signal } = {}) =>
      withFile(file, { linearSamples }, { method: "negativeScanOpen", signal }),
    // The print of `recipe`, or with `negative` the scan as the recipe frames it; cropped unless
    // `cropped` is false. Resolves to a PNG blob and its size.
    async render(handle, recipe, { maxEdge, cropped = true, negative = false, signal } = {}) {
      const result = await call(
        "negativeScanRender",
        { handle, recipe, maxEdge, cropped, negative },
        { signal },
      );
      return {
        blob: imageBlob(result.preview, result.previewType),
        width: result.width,
        height: result.height,
        colorSpace: result.colorSpace,
        renderMilliseconds: result.renderMilliseconds,
      };
    },
    sampleBorder: (handle, recipe, area) =>
      call("negativeScanSampleBorder", { handle, recipe, area }),
    detectFrame: async (handle, recipe) =>
      (await call("negativeScanDetectFrame", { handle, recipe })).crop ?? null,
    // The full-resolution positive as a photograph the editor owns: `{image, url}`, as
    // makePreview delivers one.
    async commit(handle, recipe, { signal } = {}) {
      return importedImage(await call("negativeScanCommit", { handle, recipe }, { signal }));
    },
    lightFrames: () => call("negativeLightFrames"),
    addLightFrame: (file) => withFile(file, {}, { method: "negativeAddLightFrame" }),
    removeLightFrame: (id) => call("negativeRemoveLightFrame", { id }),
    release: (handle) => call("release", { handle }),
  });
}
