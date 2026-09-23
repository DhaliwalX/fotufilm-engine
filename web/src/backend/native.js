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
