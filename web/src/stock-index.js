import { runtimeAssetUrl } from "./runtime-assets.js";
const assetUrl = (name) =>
  runtimeAssetUrl(
    name,
    import.meta.env.BASE_URL,
    globalThis.location.href,
    typeof __FOTUFILM_RUNTIME_REVISION__ === "string"
      ? __FOTUFILM_RUNTIME_REVISION__
      : "",
  );

export async function loadStockIndex() {
  const response = await fetch(assetUrl("packs/index.json"));
  if (
    !response.ok ||
    !response.headers.get("content-type")?.includes("application/json")
  ) {
    throw new Error("The film library could not be loaded.");
  }
  const index = await response.json();
  if (
    !Array.isArray(index) ||
    !index.length ||
    index.some((s) => !s.id || !s.name || !/^[a-z0-9_-]+$/i.test(s.id))
  )
    throw new Error("Invalid film library.");
  const mediaResponse = await fetch(assetUrl("packs/media.json"));
  if (!mediaResponse.ok)
    throw new Error(
      "Output media could not be loaded. Rebuild the browser packs.",
    );
  const media = await mediaResponse.json();
  const catalogueResponse = await fetch(assetUrl("profile/catalogue.json"));
  if (!catalogueResponse.ok)
    throw new Error("The film settings catalogue could not be loaded.");
  const catalogue = await catalogueResponse.json();
  return index.map((stock) => {
    if (!Array.isArray(catalogue[stock.id]?.available))
      throw new Error("Invalid film settings catalogue.");
    const entry = media.find((item) => item.id === stock.id);
    if (!entry || !Array.isArray(entry.choices) || !entry.choices.length)
      throw new Error("Invalid output-medium catalog.");
    return {
      ...stock,
      profile: catalogue[stock.id],
      available: catalogue[stock.id]?.available || [],
      nativeFormat: catalogue[stock.id]?.nativeFormat,
      media: entry.choices,
      defaultMedium: entry.default,
    };
  });
}
