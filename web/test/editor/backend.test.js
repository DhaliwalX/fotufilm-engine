import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createBackend } from "../../src/backend/create.js";
import { BACKEND_METHODS } from "../../src/backend/contract.js";
import { createImageScope } from "../../src/backend/image-scope.js";

function host() {
  const bridge = { version: 1, marker: "host" };
  for (const name of BACKEND_METHODS)
    bridge[name] = function () {
      return this.marker;
    };
  bridge.createSession = () => ({ render() {}, stages() {}, dispose() {} });
  bridge.lenses = { marker: "lenses" };
  for (const name of ["snapshot", "subscribe", "load", "import", "remove"])
    bridge.lenses[name] = function () {
      return this.marker;
    };
  return bridge;
}
test("native selection preserves host receivers without loading browser modules", async () => {
  // Node has no Worker or window; selecting native must not initialize a browser runtime.
  const backend = await createBackend(host());
  assert.equal(backend.kind, "native");
  const { importMedia } = backend,
    { snapshot } = backend.lenses;
  assert.equal(importMedia(), "host");
  assert.equal(snapshot(), "lenses");
  assert.equal(typeof backend.createSession().render, "function");
});
test("incompatible or incomplete native bridges never fall back silently", async () => {
  await assert.rejects(createBackend(null), /incompatible/);
  await assert.rejects(
    createBackend({ ...host(), version: 2 }),
    /incompatible/,
  );
  const incomplete = host();
  delete incomplete.convertNegative;
  await assert.rejects(createBackend(incomplete), /convertNegative/);
  const malformed = host();
  malformed.createSession = () => ({});
  const backend = await createBackend(malformed);
  assert.throws(() => backend.createSession(), /render/);
});
test("image scopes release cancelled/late results once and transfer accepted images", () => {
  const released = [],
    backend = { releaseImage: (image) => released.push(image) };
  const scope = createImageScope(backend),
    provisional = {},
    accepted = {},
    late = {};
  scope.image(provisional);
  scope.image(provisional);
  scope.image(accepted);
  scope.transfer(accepted);
  scope.dispose();
  scope.dispose();
  scope.image(late);
  assert.deepEqual(released, [provisional, late]);
});
test("editor's static dependency graph stays independent of browser processing", () => {
  const visited = new Set();
  const forbidden =
    /\/(?:engine|render-session|film-profile|negative-conversion|raw-import|photo-import|exr-import|video-import|video-export|lens-catalogue)\.js$/;
  function visit(url, trail) {
    if (visited.has(url.href) || !/\.[jt]sx?$/.test(url.pathname)) return;
    visited.add(url.href);
    assert.ok(!forbidden.test(url.pathname), trail.join(" → "));
    const text = readFileSync(url, "utf8");
    for (const match of text.matchAll(
      /(?:from\s+|import\s*)["'](\.[^"']+)["']/g,
    )) {
      const dependency = new URL(match[1], url);
      visit(dependency, [...trail, match[1]]);
    }
  }
  visit(new URL("../../src/main.jsx", import.meta.url), ["main.jsx"]);
});
