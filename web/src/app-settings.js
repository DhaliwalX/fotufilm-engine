import { useSyncExternalStore } from "react";

// App-wide preferences, kept on this device like the Mac app's AppSettings. Each has a default
// here; the stored value wins when there is one.
export const APP_SETTINGS = Object.freeze({
  // Choose Film Per Photo: a photograph opened for the first time picks its own film.
  autoFilm: false,
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

export function appSetting(key) {
  const stored = storage()?.getItem(PREFIX + key);
  if (stored == null) return APP_SETTINGS[key];
  try {
    return JSON.parse(stored);
  } catch {
    return APP_SETTINGS[key];
  }
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
