import { loadFilmProfile } from "./film-profile.js";

let snapshot = { profiles: [], revision: 0, loaded: false, error: null };
let ready, database;
const listeners = new Set();
export const lensCatalogueSnapshot = () => snapshot;
export const subscribeLensCatalogue = (listener) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
function publish(next) {
  snapshot = { ...snapshot, ...next };
  for (const listener of listeners) listener();
}

async function openDatabase() {
  database ??= new Promise((resolve, reject) => {
    const request = indexedDB.open("fotufilm-lens-catalogue", 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore("catalogue");
    request.onsuccess = () => {
      request.result.onversionchange = () => {
        request.result.close();
        database = null;
      };
      resolve(request.result);
    };
    request.onerror = () => reject(request.error);
    request.onblocked = () =>
      reject(new Error("Close other Fotufilm tabs to update lens profiles."));
  }).catch((error) => {
    database = null;
    throw error;
  });
  return database;
}
async function stored(profiles) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(
      "catalogue",
      profiles === undefined ? "readonly" : "readwrite",
    );
    const store = transaction.objectStore("catalogue");
    const request =
      profiles === undefined
        ? store.get("profiles")
        : store.put(profiles, "profiles");
    transaction.oncomplete = () => resolve(request.result);
    transaction.onerror = transaction.onabort = () =>
      reject(
        transaction.error || new Error("Lens profiles could not be saved."),
      );
  });
}
async function nativeJSON(request, onProgress) {
  const result = await loadFilmProfile(request, onProgress);
  return JSON.parse(new TextDecoder().decode(result));
}
export function loadLensCatalogue() {
  ready ??= (async () => {
    try {
      const profiles = await stored();
      publish({
        profiles: Array.isArray(profiles) ? profiles : [],
        loaded: true,
      });
    } catch {
      publish({
        loaded: true,
        error:
          "Saved lens profiles could not be opened. You can still import profiles for this session.",
      });
    }
    return snapshot;
  })();
  return ready.then(() => snapshot);
}
export async function importLensCatalogue(file, onProgress = () => {}) {
  if (file.size > 6 * 1024 * 1024)
    throw new Error("Choose a lens catalogue smaller than 6 MB.");
  let profiles;
  try {
    profiles = JSON.parse(await file.text());
  } catch {
    throw new Error("Choose a valid Fotufilm lens-profile JSON catalogue.");
  }
  if (!Array.isArray(profiles) || !profiles.length)
    throw new Error("Choose a Fotufilm lens-profile JSON catalogue.");
  onProgress("Checking lens profiles");
  const validated = await nativeJSON(
    { kind: "lens-catalogue", profiles },
    onProgress,
  );
  await loadLensCatalogue();
  const combined = new Map(
    snapshot.profiles.map((profile) => [profile.id, profile]),
  );
  for (const profile of validated) combined.set(profile.id, profile);
  const installed = [...combined.values()];
  if (
    new TextEncoder().encode(JSON.stringify(installed)).length >
    6 * 1024 * 1024
  )
    throw new Error(
      "The combined lens catalogue exceeds 6 MB. Remove the installed profiles first.",
    );
  let error = null;
  try {
    await stored(installed);
  } catch {
    error =
      "Profiles are available for this session, but this browser could not save them.";
  }
  publish({
    profiles: installed,
    revision: snapshot.revision + 1,
    loaded: true,
    error,
  });
  return validated.length;
}
export async function removeLensCatalogue() {
  await loadLensCatalogue();
  let error = null;
  try {
    await stored([]);
  } catch {
    error =
      "Removed from this session. This browser could not update its saved lens catalogue.";
  }
  publish({ profiles: [], revision: snapshot.revision + 1, error });
}
export async function matchedLensProfile(shot, profileID, onProgress) {
  const { profiles } = await loadLensCatalogue();
  if (!profiles.length || (!shot && !profileID)) return null;
  return nativeJSON(
    {
      kind: "lens-match",
      profiles,
      shot: shot || null,
      profileID: profileID || null,
    },
    onProgress,
  );
}
