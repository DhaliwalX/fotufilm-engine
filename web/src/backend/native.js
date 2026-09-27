import {
  BACKEND_METHODS,
  LENS_METHODS,
  validateBackend,
  requireMethods,
} from "./contract.js";

// The trusted host supplies a JS bridge backed by Swift/Halide. No browser fallback:
// an incomplete host must fail at startup instead of silently moving work to WASM.
export function createNativeBackend(host) {
  validateBackend(host);
  const lenses = Object.fromEntries(
    LENS_METHODS.map((name) => [name, host.lenses[name].bind(host.lenses)]),
  );
  const backend = {
    version: host.version,
    kind: "native",
    lenses: Object.freeze(lenses),
  };
  for (const name of BACKEND_METHODS) backend[name] = host[name].bind(host);
  // Optional: the still formats this host writes, when they are not the browser's, whether it
  // honours a negative's contrast, whether it selects subjects, and film suggestions for a scan.
  if (host.imageExportTypes) backend.imageExportTypes = Object.freeze([...host.imageExportTypes]);
  if (host.negativeContrast === true) backend.negativeContrast = true;
  if (host.subjectSelection === true) backend.subjectSelection = true;
  // Optional: how fast this host develops previews while an edit moves (preview-budget.js).
  if (host.previewBudget) backend.previewBudget = Object.freeze({ ...host.previewBudget });
  if (typeof host.suggestNegativeFilms === "function")
    backend.suggestNegativeFilms = host.suggestNegativeFilms.bind(host);
  // Optional: opening files by path, copying the picture and the still-export options, for hosts
  // with a file system, a pasteboard and an encoder of their own.
  for (const name of [
    "importPath",
    "copyImage",
    "exportOptions",
    "suggestFilm",
    "recordFilmChoice",
    "forgetFilmChoices",
  ])
    if (typeof host[name] === "function") backend[name] = host[name].bind(host);
  backend.createSession = () => {
    const session = host.createSession();
    return requireMethods(
      session,
      ["render", "stages", "dispose"],
      "Native render session",
    );
  };
  backend.createHistogram = () =>
    requireMethods(
      host.createHistogram(),
      ["analyse", "dispose"],
      "Native histogram analyser",
    );
  return Object.freeze(backend);
}
