import { createProfileRuntime } from "./profile-runtime.js";
import { relatedAssetUrl } from "./runtime-assets.js";

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
    stocks: new Map(),
  };
}

self.onmessage = async ({ data: { id, request, base } }) => {
  try {
    if (request.kind !== "lens" && !/^[a-z0-9_-]+$/i.test(request.stock))
      throw new Error("Invalid film identifier.");
    self.postMessage({ id, status: request.kind === "lens" ? "Loading on-device lens correction" : "Loading on-device film profile builder" });
    assets ??= loadAssets(base).catch((error) => {
      assets = null;
      throw error;
    });
    const { runtime, read, stocks } = await assets;
    if (request.kind === "lens") {
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
      status: "Preparing film, development and print settings",
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
