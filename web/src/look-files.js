import { defaultEdit, parseEdit } from "./editor-state.js";
import { editText } from "./saved-edits.js";
import { validateStockSettings } from "./stock-settings.js";
import { PHOTO_KEYS, SETTINGS_SECTIONS } from "./edit-settings.js";

// Look files: presets shared as a file, `Name.fotufilmlook`. A look carries a preset's sections
// and the edit they are taken from, without what belongs to the photograph it was saved from —
// its grain pattern, its clip and a scanned negative's reading — which no other photograph takes.
//
//   { "format": "fotufilm-look", "version": 1,
//     "presets": [{ "name": "…", "settings": { "sections": ["filmStock", …], "edit": {…} } }] }

export const LOOK_EXTENSION = ".fotufilmlook";
export const LOOK_TYPE = "application/x-fotufilm-look";
const FORMAT = "fotufilm-look";
const NAME_LIMIT = 100;

export const isLookFile = (name) =>
  typeof name === "string" && name.toLowerCase().endsWith(LOOK_EXTENSION);

const SECTION_IDS = new Set(SETTINGS_SECTIONS.map((section) => section.id));

// The edit as another photograph would take it.
function shareable(edit) {
  const blank = defaultEdit(edit.stock);
  return {
    ...edit,
    ...Object.fromEntries(PHOTO_KEYS.map((key) => [key, blank[key]])),
  };
}

/** The text of a look file holding `presets`. */
export const lookText = (presets) =>
  JSON.stringify(
    {
      format: FORMAT,
      version: 1,
      presets: presets.map(({ name, settings }) => ({
        name,
        settings: {
          sections: [...settings.sections],
          edit: shareable(settings.edit),
        },
      })),
    },
    null,
    2,
  );

/** A file name for `presets`: the preset's own name, or one for several. */
export function lookFileName(presets) {
  const name =
    presets.length === 1
      ? presets[0].name
          .replace(/[\p{Cc}/\\:*?"<>|]+/gu, " ")
          .replace(/\s+/g, " ")
          .trim()
          .replace(/^\.+/, "")
          .slice(0, NAME_LIMIT)
      : "";
  return `${name || "Fotufilm Presets"}${LOOK_EXTENSION}`;
}

/**
 * The presets a look file holds, each checked as a kept edit is. A look on a film that is not
 * installed is kept, to apply once the film is, and named in `missing` as `{name, film}`.
 * Sections a later version adds are left out. Throws when the file is not a look.
 */
export function readLooks(text, stocks) {
  let file;
  try {
    file = JSON.parse(text);
  } catch {
    throw new Error("This file is not a Fotufilm look.");
  }
  if (file?.format !== FORMAT || !Array.isArray(file.presets))
    throw new Error("This file is not a Fotufilm look.");
  if (file.version !== 1)
    throw new Error("This look was saved by a newer version of Fotufilm.");
  const ids = stocks.map((stock) => stock.id);
  const presets = [],
    missing = [];
  for (const entry of file.presets) {
    const name =
      typeof entry?.name === "string"
        ? entry.name.trim().slice(0, NAME_LIMIT)
        : "";
    const sections = Array.isArray(entry?.settings?.sections)
      ? entry.settings.sections.filter((id) => SECTION_IDS.has(id))
      : [];
    const source = entry?.settings?.edit;
    if (
      !name ||
      !sections.length ||
      !source ||
      typeof source !== "object" ||
      (source.stock !== null && typeof source.stock !== "string")
    )
      throw new Error("This look file is damaged.");
    let edit;
    try {
      // A film not installed is let through here and reported below.
      edit = parseEdit(editText(source), [...ids, source.stock]);
      const stock = stocks.find(({ id }) => id === edit.stock);
      if (stock) validateStockSettings(edit, stock);
      else if (edit.stock !== null) missing.push({ name, film: edit.stock });
    } catch (error) {
      throw new Error(`“${name}” could not be read. ${error.message}`);
    }
    presets.push({ name, settings: { sections, edit: shareable(edit) } });
  }
  if (!presets.length) throw new Error("This look file holds no presets.");
  return { presets, missing };
}
