import { loadFilmProfile } from "./film-profile.js";
import { lensRequest } from "./lens-correction.js";
import { matchedLensProfile } from "./lens-catalogue.js";

export async function resolveLensPlan(image, lens, onProgress = () => {}) {
  const metadata = image?.lensMetadata || {};
  const profile = await matchedLensProfile(
    metadata.shot,
    lens.profileID,
    onProgress,
  );
  const bytes = await loadFilmProfile(
    {
      ...lensRequest(lens),
      kind: "lens-plan",
      amount: lens.amount ?? 1,
      profile,
      shot: metadata.shot || null,
      embeddedTIFF: metadata.embeddedTIFF || null,
      deliveredSize: image?.raw ? [image.naturalWidth, image.naturalHeight] : null,
    },
    onProgress,
  );
  const plan = JSON.parse(new TextDecoder().decode(bytes));
  if (
    !Array.isArray(plan.table) ||
    plan.table.length !== 4096 ||
    !plan.table.every(Number.isFinite)
  )
    throw new Error("Invalid lens correction table.");
  return {
    ...plan,
    table: new Float32Array(plan.table),
    note: [plan.note, metadata.warning].filter(Boolean).join(" "),
  };
}
