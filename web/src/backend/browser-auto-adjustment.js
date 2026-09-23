import { measureTone } from "../tone-base.js";
import { decodeRGBA } from "../engine.js";
import { loadFilmProfile } from "../film-profile.js";

const measurements = new WeakMap();
const check = (signal) => {
  if (signal?.aborted)
    throw new DOMException("Auto adjustment cancelled.", "AbortError");
};

export async function solveAutoAdjustment({
  image,
  edit,
  session,
  signal,
  onProgress = () => {},
}) {
  check(signal);
  if (!image || image.video || !session)
    throw new Error("Open a photograph to use Auto Adjust.");
  onProgress("Measuring the photograph");
  const { source } = await session.source(
    image,
    edit,
    1600,
    false,
    null,
    true,
    onProgress,
  );
  check(signal);
  let stops = measurements.get(source);
  if (!stops) {
    const measurement = await measureTone(
      source,
      { ev: 0 },
      decodeRGBA,
      [1, 1, 1],
      { signal },
    );
    stops = Array.from(measurement.regionStops);
    measurements.set(source, stops);
  }
  check(signal);
  const result = JSON.parse(
    new TextDecoder().decode(
      await loadFilmProfile(
        {
          kind: "auto-adjust",
          stock: edit.stock,
          printCorrection: edit.profile.printCorrection ?? 0,
          regionStops: stops,
        },
        (message) => {
          if (!signal?.aborted) onProgress(message);
        },
      ),
    ),
  );
  check(signal);
  if (
    !Number.isFinite(result.exposureEV) ||
    Math.abs(result.exposureEV) > 3 ||
    !Number.isFinite(result.highlights) ||
    result.highlights < -1 ||
    result.highlights > 0 ||
    !Number.isFinite(result.shadows) ||
    result.shadows < 0 ||
    result.shadows > 1
  )
    throw new Error("The automatic exposure solver returned invalid settings.");
  return {
    ev: result.exposureEV,
    highlights: result.highlights,
    shadows: result.shadows,
  };
}
