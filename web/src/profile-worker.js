import { createProfileRuntime } from "./profile-runtime.js";
import { relatedAssetUrl } from "./runtime-assets.js";
import { cameraKey } from "./camera-profile.js";

let assets;
async function loadAssets(base) {
  const response = await fetch(relatedAssetUrl("index.json", base));
  if (!response.ok)
    throw new Error("Film profile builder could not be loaded.");
  const hashes = await response.json();
  const read = async (name) => {
    if (!Object.hasOwn(hashes, name))
      throw new Error("Unknown film profile asset.");
    const response = await fetch(relatedAssetUrl(name, base));
    if (!response.ok)
      throw new Error(`Film profile asset could not be loaded: ${name}`);
    const bytes = await response.arrayBuffer();
    const hash = Array.from(
      new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
      (v) => v.toString(16).padStart(2, "0"),
    ).join("");
    if (hash !== hashes[name])
      throw new Error("Film profile assets do not match. Reload the editor.");
    return bytes;
  };
  const [binary, reflectance] = await Promise.all([
    read("builder.wasm"),
    read("rec2020-reflectance-prior.coeff"),
  ]);
  return {
    runtime: await createProfileRuntime(binary, reflectance),
    read,
    has: (name) => Object.hasOwn(hashes, name),
    stocks: new Map(),
    cameras: new Map(),
  };
}

// The measured channels of the camera a scanned negative's file names, as the record the desktop
// app carries of it (tools/build-web-profile.sh ships them beside the builder, which carries
// none): null for a camera nobody measured, or assets built before the records shipped.
const CAMERAS = "cameras.json";
async function cameraRecord({ read, has, cameras }, camera) {
  const key = cameraKey(camera?.make, camera?.model);
  if (!key || !has(CAMERAS)) return null;
  if (!cameras.has(CAMERAS))
    cameras.set(CAMERAS, JSON.parse(new TextDecoder().decode(await read(CAMERAS))));
  const found = cameras.get(CAMERAS).find(({ make, model }) => cameraKey(make, model) === key);
  if (!found) return null;
  if (!cameras.has(found.file))
    cameras.set(found.file, new TextDecoder().decode(await read(found.file)));
  return cameras.get(found.file);
}

// A request that reads a negative, with the record of the camera its scan's file names.
async function withCamera(assets, request) {
  const negative = request.kind === "negative-camera" ? request : request.negative;
  const cameraProfile = negative?.source
    ? await cameraRecord(assets, negative.source.camera)
    : null;
  if (!cameraProfile) return request;
  return negative === request
    ? { ...request, cameraProfile }
    : { ...request, negative: { ...negative, cameraProfile } };
}

self.onmessage = async ({ data: { id, request: asked, base } }) => {
  try {
    let request = asked;
    const lensRequest = [
      "lens",
      "lens-plan",
      "lens-catalogue",
      "lens-match",
    ].includes(request.kind);
    const perspectiveRequest = request.kind === "perspective";
    const autoRequest = request.kind === "auto-adjust";
    const frameRequest = request.kind === "print-frame";
    const needsStock =
      !["negative-film", "negative-plain", "negative-camera"].includes(request.kind) &&
      !perspectiveRequest &&
      !lensRequest &&
      !((autoRequest || frameRequest) && request.stock == null);
    if (needsStock && !/^[a-z0-9_-]+$/i.test(request.stock))
      throw new Error("Invalid film identifier.");
    self.postMessage({
      id,
      status: perspectiveRequest
        ? "Preparing perspective correction"
        : frameRequest
          ? "Preparing print frame"
          : autoRequest
            ? "Solving automatic exposure"
            : lensRequest
              ? "Loading on-device lens correction"
              : "Loading on-device film profile builder",
    });
    assets ??= loadAssets(base).catch((error) => {
      assets = null;
      throw error;
    });
    const loaded = await assets;
    const { runtime, read, stocks } = loaded;
    request = await withCamera(loaded, request);
    if (!needsStock) {
      const profile = runtime.prepare(request);
      self.postMessage({ id, profile }, [profile]);
      return;
    }
    if (!stocks.has(request.stock)) {
      const bytes = await read(`stocks/${request.stock}.json`);
      stocks.set(request.stock, JSON.parse(new TextDecoder().decode(bytes)));
    }
    self.postMessage({
      id,
      status: perspectiveRequest
        ? "Preparing perspective correction"
        : frameRequest
          ? "Preparing print frame"
          : autoRequest
            ? "Matching exposure to the film’s latitude"
            : "Preparing film, development and print settings",
    });
    const profile = runtime.prepare({
      ...request,
      stock: stocks.get(request.stock),
    });
    self.postMessage({ id, profile }, [profile]);
  } catch (error) {
    self.postMessage({ id, error: error.message });
  }
};
