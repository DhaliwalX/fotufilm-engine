import { preferredCanvasColorSpace } from "./canvas-color.js";
import { createBackgroundDeveloper } from "./background-developer.js";

// The small import placeholder uses a short-lived CPU worker. The editing session
// owns GPU warm-up and the final preview, so importing never compiles duplicate shaders.
export async function developImportPreview(
  source,
  controls,
  { signal, onProgress = () => {} } = {},
) {
  if (signal?.aborted)
    throw new DOMException("Import cancelled.", "AbortError");
  const developer = await createBackgroundDeveloper(
    null,
    onProgress,
    () => {},
    { preferGpu: false },
  );
  const cancel = () => developer.dispose();
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    const colorSpace = preferredCanvasColorSpace();
    const result = await developer.develop(
      source,
      controls,
      onProgress,
      () => !!signal?.aborted,
      { colorSpace },
    );
    if (!result || signal?.aborted)
      throw new DOMException("Import cancelled.", "AbortError");
    return { ...result, colorSpace };
  } finally {
    signal?.removeEventListener("abort", cancel);
    developer.dispose();
  }
}
