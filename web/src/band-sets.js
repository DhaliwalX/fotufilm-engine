import { useSyncExternalStore } from "react";

// Receiver bands saved under a name, kept on this device beside the edit presets and apart from
// the app settings, so resetting those leaves them. Each set is `{name, red, green, blue}` in nm.
const KEY = "fotufilm.receiverBandSets";
export const BAND_FIELDS = ["screenRedBand", "screenGreenBand", "screenBlueBand"];
const listeners = new Set();
let stored = null;

function storage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

function read() {
  if (stored) return stored;
  let value = null;
  try {
    value = JSON.parse(storage()?.getItem(KEY) ?? "null");
  } catch {
    value = null;
  }
  stored = Array.isArray(value)
    ? value.filter(
        (set) =>
          typeof set?.name === "string" &&
          ["red", "green", "blue"].every((band) => Number.isFinite(set[band])),
      )
    : [];
  return stored;
}

function write(next) {
  stored = next;
  try {
    storage()?.setItem(KEY, JSON.stringify(next));
  } catch {
    // Private windows refuse storage; the sets last for the session.
  }
  for (const listener of listeners) listener();
}

/** Saves `bands` under `name`, replacing a set of the same name. */
export function saveBandSet(name, bands) {
  const set = { name, red: bands.red, green: bands.green, blue: bands.blue };
  write(
    [...read().filter((s) => s.name !== name), set].sort((a, b) =>
      a.name.localeCompare(b.name, undefined, { numeric: true }),
    ),
  );
  return set;
}

export function deleteBandSet(name) {
  write(read().filter((s) => s.name !== name));
}

/** The peaks of an edit's profile, the paper's where a band is unset. */
export function editBands(profile, paper) {
  return {
    red: profile?.screenRedBand ?? paper.red,
    green: profile?.screenGreenBand ?? paper.green,
    blue: profile?.screenBlueBand ?? paper.blue,
  };
}

export const sameBands = (a, b) =>
  !!a && !!b && a.red === b.red && a.green === b.green && a.blue === b.blue;

function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
/** The saved sets, sorted by name, re-rendering as they change. */
export const useBandSets = () => useSyncExternalStore(subscribe, read, read);
