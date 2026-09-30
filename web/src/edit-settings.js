import { useSyncExternalStore } from "react";
import { EDITOR_CONTROLS, SETTINGS_SECTIONS } from "./generated/controls.js";

// Copy Settings, Paste Settings and presets. An edit travels by inspector section, the same
// sections the Mac and iOS apps copy (EditorControlSection.transferable in the catalogue).

export { SETTINGS_SECTIONS };
export const DEFAULT_SECTIONS = SETTINGS_SECTIONS.filter(
  (s) => s.byDefault,
).map((s) => s.id);

// The catalogue control each of the edit's own keys belongs to, where the names differ.
const FIELD = {
  format: "gauge",
  filters: "lensFilterStack",
  filterMetering: "metering",
  lens: "lensCorrection",
  medium: "paper",
  mediumFollowsFilm: "paper",
  perspectiveV: "perspectiveVertical",
  perspectiveH: "perspectiveHorizontal",
  cropShape: "crop",
  ratio: "crop",
  ev: "exposure",
  temperature: "warmth",
};
// The photograph's own: its grain pattern and its clip.
export const PHOTO_KEYS = ["seed", "video"];

const sectionOfField = Object.fromEntries(
  EDITOR_CONTROLS.map((c) => [c.field, c.section]),
);
/**
 * The section an edit key (or a `params`/`profile` field) travels in; null for the photograph's
 * own, and for a field a later version no longer has.
 */
export const sectionOf = (key) =>
  PHOTO_KEYS.includes(key) ? null : (sectionOfField[FIELD[key] ?? key] ?? null);

/** The sections of `edit` to paste elsewhere. */
export const copySettings = (edit, sections) => ({
  sections: [...sections],
  edit,
});

/** `edit` with the sections `settings` carries taken from its edit. */
export function pasteSettings(edit, settings) {
  const chosen = (key) => settings.sections.includes(sectionOf(key));
  const source = settings.edit;
  const pasted = { ...edit };
  for (const key of Object.keys(edit))
    if (key !== "params" && key !== "profile" && chosen(key) && key in source)
      pasted[key] = source[key];
  pasted.params = { ...edit.params };
  for (const key of Object.keys(edit.params))
    if (chosen(key) && key in source.params)
      pasted.params[key] = source.params[key];
  // A field absent from the profile is at the film's own value, so a chosen section is replaced
  // whole: fields the source left alone are left alone here too.
  pasted.profile = Object.fromEntries([
    ...Object.entries(edit.profile ?? {}).filter(([field]) => !chosen(field)),
    ...Object.entries(source.profile ?? {}).filter(([field]) => chosen(field)),
  ]);
  return pasted;
}

// Presets and the sections last ticked are kept on this device, apart from the app settings so
// that resetting those leaves them. What was copied lasts for the session, as a clipboard does.
const KEY = "fotufilm.editPresets";
const listeners = new Set();
let copied = null;
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
  try {
    stored = JSON.parse(storage()?.getItem(KEY) ?? "null");
  } catch {
    stored = null;
  }
  stored = {
    presets: stored?.presets ?? [],
    sections: stored?.sections ?? DEFAULT_SECTIONS,
  };
  return stored;
}

function write(next) {
  stored = next;
  storage()?.setItem(KEY, JSON.stringify(next));
  changed();
}

function changed() {
  snapshot = null;
  for (const listener of listeners) listener();
}

export function setCopiedSettings(settings) {
  copied = settings;
  write({ ...read(), sections: settings.sections });
}

/** Saves a preset, replacing one of the same name. */
export function savePreset(name, settings) {
  const { presets: list, ...rest } = read();
  const preset = { id: crypto.randomUUID(), name, settings };
  write({
    ...rest,
    sections: settings.sections,
    presets: [...list.filter((p) => p.name !== name), preset].sort((a, b) =>
      a.name.localeCompare(b.name, undefined, { numeric: true }),
    ),
  });
  return preset;
}

export function deletePreset(id) {
  const state = read();
  write({ ...state, presets: state.presets.filter((p) => p.id !== id) });
}

let snapshot = null;
function current() {
  snapshot ??= { copied, ...read() };
  return snapshot;
}
function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
/** `{copied, presets, sections}`, re-rendering as they change. */
export const useEditSettings = () =>
  useSyncExternalStore(subscribe, current, current);
