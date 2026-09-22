import { preferredCanvasColorSpace } from "./canvas-color.js";
import { createBackgroundDeveloper } from "./background-developer.js";
import { developNormalReference } from "./engine.js";

// Import placeholders use the bounded scene-linear reference, without another
// WASM heap. The editing session owns GPU preparation and the final preview.
export async function developImportPreview(
  source,
  controls,
  { signal, onProgress = () => {} } = {},
) {
  if (signal?.aborted)
    throw new DOMException("Import cancelled.", "AbortError");
  let developer, result;
  const colorSpace = preferredCanvasColorSpace();
  const stale = () => !!signal?.aborted;
  try {
    developer = await createBackgroundDeveloper(null, onProgress, () => {}, {
      previewOnly: true,
      signal,
    });
    if (!developer || stale())
      throw new DOMException("Import cancelled.", "AbortError");
    result = await developer.develop(source, controls, onProgress, stale, {
      colorSpace,
    });
  } catch (error) {
    developer?.dispose();
    if (stale() || error.name === "AbortError") throw error;
    // A worker failure must not discard pixels already decoded successfully.
    // The same transform yields between bounded strips when run on the UI thread.
    console.warn(
      "Import preview worker unavailable; preparing in strips:",
      error,
    );
    result = await developNormalReference(source, controls, onProgress, stale, {
      colorSpace,
    });
  } finally {
    developer?.dispose();
  }
  if (!result || stale())
    throw new DOMException("Import cancelled.", "AbortError");
  return { ...result, colorSpace };
}
