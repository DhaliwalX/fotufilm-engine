import test from "node:test";
import assert from "node:assert/strict";
import { createMacBackend } from "../../src/backend/macos/host.js";

const channel = (capabilities) => ({
  binary: true,
  capabilities,
  async postMessage() {
    return {};
  },
});

test("a host without capabilities offers only the required methods", () => {
  const backend = createMacBackend(channel(undefined));
  assert.equal(backend.subjectSelection, false);
  assert.equal(backend.negativeContrast, false);
  assert.equal(backend.importPath, undefined);
  assert.equal(backend.copyImage, undefined);
  assert.equal(backend.exportOptions, undefined);
  assert.deepEqual(
    backend.imageExportTypes.map(({ id }) => id),
    ["image/png", "image/tiff", "image/jpeg", "image/heic"],
  );
});

test("the engine's platform services decide what the editor offers", () => {
  const backend = createMacBackend(
    channel({
      importPath: true,
      negativeContrast: true,
      subjectSelection: true,
      copyImage: false,
      imageExportTypes: ["image/tiff", "image/png"],
    }),
  );
  assert.equal(backend.subjectSelection, true);
  assert.equal(backend.negativeContrast, true);
  assert.equal(typeof backend.importPath, "function");
  assert.equal(backend.copyImage, undefined);
  assert.equal(typeof backend.exportOptions, "function");
  assert.deepEqual(
    backend.imageExportTypes.map(({ id }) => id),
    ["image/png", "image/tiff"],
  );
});
