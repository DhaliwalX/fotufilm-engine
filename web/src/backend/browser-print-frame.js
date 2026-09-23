import { loadFilmProfile } from "../film-profile.js";
import { frameRequest } from "../print-frame.js";
export async function loadPrintFrame(edit, width = 1, height = 1, onProgress) {
  return JSON.parse(
    new TextDecoder().decode(
      await loadFilmProfile(frameRequest(edit, width, height), onProgress),
    ),
  );
}
