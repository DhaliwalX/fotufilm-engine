import { useSyncExternalStore } from "react";

// App-wide preferences, kept on this device like the Mac app's AppSettings. Each has a default
// here; the stored value wins when there is one.
export const APP_SETTINGS = Object.freeze({
  // Choose Film Per Photo: a photograph opened for the first time picks its own film.
  autoFilm: false,
  // What a newly opened photograph starts on. A null film keeps the film in use; a null format
  // matches the film.
  startingFilm: null,
  startingFormat: null,
  // The film model new photographs develop with (Settings › Film Model on the Mac).
  grainModel: "clump",
  halationModel: "legacy",
  estimatedHalation: false,
  // Color Separation (Settings › Film Model on the Mac): how far the inhibitor reaches between
  // layers and within one, as multiples of each film's own geometry. Red–Green and Green–Blue
  // reach through one interlayer each; null follows Separation until one is moved on its own.
  couplerReach: 1,
  couplerRedGreen: null,
  couplerGreenBlue: null,
  couplerSelf: 1,
  // Whether a HEIC export starts as HDR where the edit allows it.
  photoHDR: false,
  // Whether an HEVC or ProRes movie exports as HDR (HLG) where the film delivers it.
  videoHDR: false,
  // Video File Size: what a native movie export may spend per pixel (the backend's
  // `videoBitrates`; "automatic" leaves it to the encoder).
  videoBitrate: "automatic",
  // Video Quality: a native movie export develops the film at the delivered size ("full") or at
  // no more than 1080p ("fast"), where the backend offers the choice (`videoProcessing`).
  videoProcessing: "full",
  // Photo Quality: exports evaluate the film exactly ("accurate") or approximately ("fast").
  photoQuality: "accurate",
  // The settings of the last photo and movie exported, for Use Last Export Settings.
  lastPhotoExport: null,
  lastVideoExport: null,
  // The plug-in build whose launch offer was declined ("Not Now"); a later build asks again.
  pluginOfferDeclined: null,
});

const PREFIX = "fotufilm.setting.";
const listeners = new Set();

function storage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

// The value last read for each key, by its stored text: an object setting reads back as the same
// object until it changes, as useSyncExternalStore requires of a snapshot.
const parsed = new Map();

export function appSetting(key) {
  const stored = storage()?.getItem(PREFIX + key);
  if (stored == null) return APP_SETTINGS[key];
  const cached = parsed.get(key);
  if (cached?.stored === stored) return cached.value;
  let value;
  try {
    value = JSON.parse(stored);
  } catch {
    return APP_SETTINGS[key];
  }
  parsed.set(key, { stored, value });
  return value;
}

export function setAppSetting(key, value) {
  if (!(key in APP_SETTINGS)) throw new Error(`Unknown setting: ${key}`);
  storage()?.setItem(PREFIX + key, JSON.stringify(value));
  for (const listener of listeners) listener();
}

function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useAppSetting(key) {
  return useSyncExternalStore(subscribe, () => appSetting(key), () => APP_SETTINGS[key]);
}

/** Every setting back to its default. */
export function resetAppSettings() {
  for (const key of Object.keys(APP_SETTINGS)) storage()?.removeItem(PREFIX + key);
  for (const listener of listeners) listener();
}

/**
 * A newly opened photograph's edit: `base` (the editor's default edit on `currentFilm`) with the
 * starting film, format and film model the settings choose. Films the library lacks are ignored.
 */
export function newPhotoEdit(base, stockIDs) {
  const film = appSetting("startingFilm");
  const edit = { ...base, profile: { ...base.profile } };
  if (film === "none") edit.stock = null;
  else if (film && (!stockIDs || stockIDs.includes(film))) edit.stock = film;
  if (appSetting("startingFormat")) edit.format = appSetting("startingFormat");
  edit.halationModel = appSetting("halationModel");
  if (appSetting("grainModel") !== APP_SETTINGS.grainModel)
    edit.profile.grainModel = appSetting("grainModel");
  if (appSetting("estimatedHalation")) edit.profile.estimatedHalation = true;
  for (const key of ["couplerReach", "couplerSelf"])
    if (appSetting(key) !== APP_SETTINGS[key]) edit.profile[key] = appSetting(key);
  // A pair set on its own starts the photo there; one left linked follows Separation.
  for (const key of ["couplerRedGreen", "couplerGreenBlue"])
    if (appSetting(key) != null && appSetting(key) !== appSetting("couplerReach"))
      edit.profile[key] = appSetting(key);
  return edit;
}
