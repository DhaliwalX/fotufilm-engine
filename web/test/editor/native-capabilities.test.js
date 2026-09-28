import test from "node:test";
import assert from "node:assert/strict";
import { createDesktopBackend } from "../../src/backend/desktop/host.js";
import { createSession } from "../../src/backend/desktop/session.js";
import { defaultEdit } from "../../src/editor-state.js";

const channel = (capabilities) => ({
  binary: true,
  capabilities,
  async postMessage() {
    return {};
  },
});

test("a host without capabilities offers only the required methods", () => {
  const backend = createDesktopBackend(channel(undefined));
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
  const backend = createDesktopBackend(
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

test("the plug-ins a host installs are named up front and read through the engine", async () => {
  const calls = [];
  const backend = createDesktopBackend({
    binary: true,
    capabilities: {
      plugins: [
        { id: "resolve", name: "DaVinci Resolve" },
        { id: "finalCut", name: "Final Cut Pro" },
      ],
    },
    async postMessage(message) {
      calls.push([message.method, message.params]);
      return [];
    },
  });
  assert.deepEqual(
    backend.plugins.map(({ id }) => id),
    ["resolve", "finalCut"],
  );
  await backend.pluginStatus();
  await backend.installPlugin("resolve");
  await backend.revealPlugin("finalCut");
  assert.deepEqual(
    calls.map(([method]) => method),
    ["plugins", "installPlugin", "revealPlugin"],
  );
  assert.deepEqual(calls[1][1], { id: "resolve" });
  // A host that installs none offers no plug-in calls at all.
  const bare = createDesktopBackend(channel({ plugins: [] }));
  assert.equal(bare.plugins, undefined);
  assert.equal(bare.installPlugin, undefined);
});

test("a file the host opens carries the identity its edit is kept under", async () => {
  const backend = createDesktopBackend({
    binary: true,
    capabilities: { importPath: true },
    async postMessage({ method }) {
      assert.equal(method, "importPath");
      return {
        handle: 4,
        naturalWidth: 2,
        naturalHeight: 1,
        preview: new Uint8Array([1]),
        identity: "sha256:ab",
      };
    },
  });
  const opened = await backend.importPath("/photos/a.jpg");
  assert.equal(opened.identity, "sha256:ab");
  assert.equal(opened.image.identity, undefined);
  assert.equal(opened.image.handle, 4);
  URL.revokeObjectURL(opened.url);
});

test("a host that draws the photograph itself gets frames placed instead of pictures", async () => {
  const calls = [];
  const call = async (method, params) => {
    calls.push([method, params]);
    if (method === "render")
      return {
        width: 4,
        height: 2,
        presented: { frame: 7, original: 3, dynamicRange: "hdr", headroom: 4 },
      };
    return [];
  };
  const backend = createDesktopBackend({
    binary: true,
    capabilities: { imageLayer: true },
    postMessage: ({ method, params }) => call(method, params),
  });
  assert.equal(backend.imageLayer, true);
  const session = createSession(call, async () => [], { imageLayer: true });
  const image = { handle: 5 };
  const result = await session.render({ image, edit: defaultEdit(), maxEdge: 64, present: "preview" });
  assert.equal(result.presented.frame, 7);
  assert.equal(result.blob, undefined);
  assert.deepEqual(calls.at(-1)[1].present, { slot: "preview", scope: "5|photo|" });
  assert.equal(result.sceneRequest, calls.at(-1)[1]);
  // A tile's scope is its region, so an older tile is never shown for a newer one.
  const viewport = { width: 8, height: 4, region: { x: 4, y: 0, width: 4, height: 2 } };
  await session.render({ image, edit: defaultEdit(), maxEdge: 64, present: "detail", viewport });
  assert.equal(calls.at(-1)[1].present.scope, `5|photo||${JSON.stringify(viewport)}`);
  await backend.placeImageLayer({ clip: [0, 0, 1, 1], source: "developed", layers: [] });
  assert.equal(calls.at(-1)[0], "setImageLayer");
  session.dispose();

  const plain = createDesktopBackend(channel({}));
  assert.equal(plain.imageLayer, false);
  assert.equal(plain.placeImageLayer, undefined);
});
