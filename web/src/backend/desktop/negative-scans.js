import { fileBase64 } from "./transport.js";

// Scanned negatives in the editor (Sources/FotufilmHost/HostService+NegativeScan.swift): a scan
// opens as a document through `importMedia`/`importPath` with `negative`, and every develop of it
// prints the framed scan as the edit's film. These are the calls a negative's Film panel makes.
// `binary` hosts send file bytes beside the message; WebKit's sends base64.
export function createNegativeScans(call, { binary }) {
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
    // Clear film where `point` falls on a shown render: linear Rec. 2020 scan RGB.
    sampleFilmBase: (result, point) =>
      call("negativeSampleFilmBase", { render: result.sceneRequest, point }),
    lightFrames: () => call("negativeLightFrames"),
    addLightFrame: (file) => withFile(file, {}, { method: "negativeAddLightFrame" }),
    removeLightFrame: (id) => call("negativeRemoveLightFrame", { id }),
  });
}
