import test from "node:test";
import assert from "node:assert/strict";
import { createDesktopBackend } from "../../src/backend/desktop/host.js";
import { createNativeBackend } from "../../src/backend/native.js";
import { isFilmPack, packNotice } from "../../src/editor/useFilmPacks.js";
import { createPhotoView } from "../../src/photo-view.js";
import { menuState } from "../../src/editor/useNativeCommands.js";

const host = (capabilities, answer = () => ({})) => {
  const calls = [];
  const backend = createDesktopBackend({
    binary: true,
    capabilities,
    async postMessage(message, payload) {
      calls.push([message.method, message.params, payload]);
      return answer(message);
    },
  });
  return { backend, calls };
};

test("only a host that installs packs offers them", () => {
  assert.equal(host({}).backend.filmPacks, undefined);
  const { backend } = host({ filmPacks: true });
  assert.deepEqual(Object.keys(backend.filmPacks).sort(), [
    "importFile",
    "importPath",
    "list",
    "remove",
  ]);
  // The native binding carries them through, with the film reload beside them.
  const bound = createNativeBackend(backend);
  assert.equal(typeof bound.filmPacks.importPath, "function");
  assert.equal(typeof bound.reloadStocks, "function");
  assert.equal(createNativeBackend(host({}).backend).filmPacks, undefined);
});

test("packs go to the engine by path or as bytes, and the film list is asked for again", async () => {
  let prepared = 0;
  const { backend, calls } = host({ filmPacks: true }, ({ method }) => {
    if (method === "prepare") {
      prepared += 1;
      return { stocks: ["gold200"], catalogue: [{ id: "gold200" }] };
    }
    return {
      added: true,
      title: "Pack added",
      message: "Pack v1 — Film",
      packs: [],
    };
  });
  await backend.loadStocks();
  const added = await backend.filmPacks.importPath("/packs/one.fotufilmpack");
  assert.equal(added.title, "Pack added");
  await backend.filmPacks.importFile(
    new File([new Uint8Array([1, 2, 3])], "two.fotufilmpack"),
  );
  await backend.filmPacks.remove("one");
  assert.deepEqual(calls.map(([method, params]) => [method, params]).slice(1), [
    ["importFilmPack", { path: "/packs/one.fotufilmpack" }],
    ["importFilmPack", { name: "two.fotufilmpack" }],
    ["removeFilmPack", { packID: "one" }],
  ]);
  assert.equal(calls[2][2].byteLength, 3);
  await backend.loadStocks();
  assert.equal(prepared, 1);
  backend.reloadStocks();
  await backend.loadStocks();
  assert.equal(prepared, 2);
});

test("pack files are told apart and several results read as one notice", () => {
  assert.equal(isFilmPack("Portra.FOTUFILMPACK"), true);
  assert.equal(isFilmPack("photo.jpg"), false);
  const one = { added: true, title: "Pack added", message: "A v1 — 3 films" };
  assert.equal(packNotice([one]), one);
  const both = packNotice([
    one,
    { added: false, title: "Pack not added", message: "why" },
  ]);
  assert.equal(both.title, "Film packs");
  assert.equal(
    both.message,
    "Pack added: A v1 — 3 films\n\nPack not added: why",
  );
});

test("File › Import Film Pack follows the capability and waits out an export", () => {
  const base = {
    backend: {},
    active: null,
    stocks: [],
    history: { past: [], future: [] },
    auto: {},
    exporting: false,
    libraryOpen: false,
    dialog: null,
    photoView: createPhotoView(),
    editSettings: { copied: null, presets: [], sections: [] },
  };
  assert.equal(menuState(base).enabled.importFilmPack, false);
  assert.equal(
    menuState({ ...base, filmPacks: {} }).enabled.importFilmPack,
    true,
  );
  assert.equal(
    menuState({ ...base, filmPacks: {}, exporting: true }).enabled
      .importFilmPack,
    false,
  );
});
