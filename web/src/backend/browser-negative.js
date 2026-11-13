import { defaultEdit } from "../editor-state.js";
import { loadFilmProfile } from "../film-profile.js";
import { decodeRGBA } from "../engine.js";
import { NEGATIVE } from "../engine-constants.js";
import { areaPreview, filmBase, pickedNeutral } from "../negative-reading.js";
import { rawSource, scaledLinearImage } from "../raw-source.js";
import { loadStockIndex } from "../stock-index.js";
import { importMedia } from "./browser-import.js";

// Scanned negatives in the browser: a scan opens as a document, and every render of it reads the
// framed scan as the edit's film and prints it (RenderSession.negativeReading). Light frames are
// kept by the desktop host only.

// A scan opened with `negative` carries the films its clear base looks like, the reading a new
// edit of it is made with, and the camera it is read as taken with where the edit leaves that to
// its file, as the desktop host describes a negative it opens
// (Sources/FotufilmHost/HostService+NegativeScan.swift `importNegative`).
export async function importNegativeMedia(file, options) {
  const opened = await importMedia(file, options);
  if (options?.negative) {
    const [films, camera] = await Promise.all([
      suggestNegativeFilms(opened.image).catch(() => ({ suggestions: [], base: null })),
      readCamera(opened.image).catch(() => ({ id: "generic" })),
    ]);
    // `base`: the film's base where the scan shows its bare light past the film, which the
    // current reading is measured against until clear film is picked (RenderSession).
    opened.image.negative = {
      suggestions: films.suggestions,
      reading: NEGATIVE.currentReading,
      camera,
      base: films.base,
    };
  }
  return opened;
}

// What a scan's file says of its camera and decode (camera-profile.js `scanSource`): only a
// camera RAW says anything.
export const scanSourceOf = (image) => image?.raw?.scanSource ?? null;

// The camera a scan is read as taken with (WebNegativeCameraRequest): `id` as an edit names it,
// and a measured camera's `name`.
async function readCamera(image) {
  const bytes = await loadFilmProfile({ kind: "negative-camera", source: scanSourceOf(image) });
  return JSON.parse(new TextDecoder().decode(bytes));
}

export const negativeScans = Object.freeze({
  // Clear film where `point` falls on a shown render: linear Rec. 2020 scan RGB.
  sampleFilmBase: async (result, point) => filmBase(result.scanSource, point),
  // Something neutral in the picture there, read the same way.
  sampleNeutral: async (result, point) => pickedNeutral(result.scanSource, point),
  // Exposures under red, green and blue light merged into scans, each offered as a download.
  mergeTrichromatic: async (files, options) =>
    (await import("./browser-trichromatic.js")).mergeTrichromatic(files, options),
});

// The suggestions read one 512-pixel copy of the whole scan by area (areaPreview), packed as
// planar little-endian float32: that keeps it under the WASI request limit without rounding
// transmission values.
function scanPreview(image) {
  const scan = image.raw || image.linear ? image : scaledLinearImage(image, 2048);
  const source = rawSource(scan, defaultEdit(), 2048);
  const { pixels, width, height } = areaPreview(
    decodeRGBA(source.read(0, 0, source.width, source.height)),
    source.width,
    source.height,
  );
  if (width < 2 || height < 2) return null;
  const count = width * height;
  const packed = new Uint8Array(count * 3 * 4);
  const view = new DataView(packed.buffer);
  for (let c = 0; c < 3; c++)
    for (let i = 0; i < count; i++)
      view.setFloat32((c * count + i) * 4, pixels[4 * i + c], true);
  const chunks = [];
  for (let i = 0; i < packed.length; i += 16384)
    chunks.push(String.fromCharCode(...packed.subarray(i, i + 16384)));
  return { width, height, samples: btoa(chunks.join("")) };
}

// The installed negatives and their predicted clear bases, read once.
let negativeFilms = null;
function loadNegativeFilms() {
  negativeFilms ??= loadStockIndex().then((stocks) =>
    stocks
      .filter((stock) => stock.profile.filmBase)
      .map(({ id, name, profile }) => ({
        id,
        name,
        base: profile.filmBase,
        ...(profile.filmBaseSpectrum ? { spectrum: profile.filmBaseSpectrum } : {}),
      })),
  );
  return negativeFilms.catch((error) => {
    negativeFilms = null;
    throw error;
  });
}

// Up to three readings of the scan's film base, each naming the installed films it could be, and
// the base itself where the scan shows its bare light past the film.
async function suggestNegativeFilms(image) {
  const films = await loadNegativeFilms();
  const preview = scanPreview(image);
  if (!preview) return { suggestions: [], base: null };
  const source = scanSourceOf(image);
  const bytes = await loadFilmProfile({
    kind: "negative-film",
    ...preview,
    films,
    ...(source ? { source } : {}),
  });
  const names = new Map(films.map((film) => [film.id, film.name]));
  const read = JSON.parse(new TextDecoder().decode(bytes));
  return {
    suggestions: read.suggestions.map((suggestion) => ({
      films: suggestion.films.map((id) => ({ id, name: names.get(id) })),
      likelihood: suggestion.likelihood,
    })),
    base: read.base ?? null,
  };
}
