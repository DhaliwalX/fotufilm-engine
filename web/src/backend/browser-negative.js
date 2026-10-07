import { defaultEdit } from "../editor-state.js";
import { loadFilmProfile } from "../film-profile.js";
import { decodeRGBA } from "../engine.js";
import { areaPreview, filmBase } from "../negative-reading.js";
import { rawSource, scaledLinearImage } from "../raw-source.js";
import { loadStockIndex } from "../stock-index.js";
import { importMedia } from "./browser-import.js";

// Scanned negatives in the browser (backend/README.md, Negative scans): a scan opens as a
// document, and every render of it reads the framed scan as the edit's film and prints it
// (RenderSession.negativeReading). Light frames are kept by the desktop host only.

// A scan opened with `negative` carries the films its clear base looks like.
export async function importNegativeMedia(file, options) {
  const opened = await importMedia(file, options);
  if (options?.negative)
    opened.image.negative = {
      suggestions: await suggestNegativeFilms(opened.image).catch(() => []),
    };
  return opened;
}

export const negativeScans = Object.freeze({
  // Clear film where `point` falls on a shown render: linear Rec. 2020 scan RGB.
  sampleFilmBase: async (result, point) => filmBase(result.scanSource, point),
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
      .map(({ id, name, profile }) => ({ id, name, base: profile.filmBase })),
  );
  return negativeFilms.catch((error) => {
    negativeFilms = null;
    throw error;
  });
}

// Up to three readings of the scan's film base, each naming the installed films it could be.
async function suggestNegativeFilms(image) {
  const films = await loadNegativeFilms();
  const preview = films.length ? scanPreview(image) : null;
  if (!preview) return [];
  const bytes = await loadFilmProfile({ kind: "negative-film", ...preview, films });
  const names = new Map(films.map((film) => [film.id, film.name]));
  return JSON.parse(new TextDecoder().decode(bytes)).suggestions.map((suggestion) => ({
    films: suggestion.films.map((id) => ({ id, name: names.get(id) })),
    likelihood: suggestion.likelihood,
  }));
}
