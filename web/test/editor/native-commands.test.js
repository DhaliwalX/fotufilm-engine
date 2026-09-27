import test from "node:test";
import assert from "node:assert/strict";
import {
  MENU_PANELS,
  menuState,
  runCommand,
} from "../../src/editor/useNativeCommands.js";

function editor(overrides = {}) {
  const calls = [];
  const record =
    (name) =>
    (...args) =>
      calls.push([name, ...args]);
  const value = {
    calls,
    backend: { copyImage() {} },
    session: {},
    active: { image: {} },
    stocks: [{ id: "gold200" }],
    history: { past: [{}], future: [] },
    auto: { available: true, active: false, toggle: record("auto") },
    shownResult: {},
    zoom: 1,
    panel: "film",
    inspectorOpen: true,
    filmOpen: true,
    exporting: false,
    libraryOpen: false,
    dialog: null,
    dispatch: record("dispatch"),
    setDialog: record("dialog"),
    removeFile: record("remove"),
    setInspector: record("inspector"),
    setSampling: record("sampling"),
    copyPhoto: record("copy"),
    resetEdits: record("reset"),
    zoomIn: record("zoomIn"),
    zoomOut: record("zoomOut"),
    setZoom: record("zoom"),
    setCompare: record("compare"),
    setHistogram: record("histogram"),
    toggleFilms: record("films"),
    toggleInspector: record("toggleInspector"),
    ...overrides,
  };
  return value;
}

test("menu commands run the editor's own handlers", () => {
  const e = editor();
  assert.ok(runCommand(e, "undo"));
  assert.ok(runCommand(e, "export"));
  assert.ok(runCommand(e, "sampleSelection"));
  assert.ok(runCommand(e, "panel:crop"));
  assert.ok(runCommand(e, "closePhoto"));
  assert.deepEqual(e.calls, [
    ["dispatch", { type: "undo" }],
    ["dialog", "export"],
    ["inspector", "selective"],
    ["sampling", true],
    ["inspector", "crop"],
    ["remove", e.active],
  ]);
  assert.equal(runCommand(e, "unknown"), false);
});

test("commands that do not apply are greyed and refused", () => {
  const e = editor({ history: { past: [], future: [] }, zoom: 1 });
  const { enabled } = menuState(e);
  assert.equal(enabled.undo, false);
  assert.equal(enabled.zoomOut, false);
  assert.equal(enabled.zoomIn, true);
  assert.equal(runCommand(e, "undo"), false);
  // A video has no selection to sample and no still to copy.
  const video = menuState(editor({ active: { image: { video: {} } } })).enabled;
  assert.equal(video.sampleSelection, false);
  assert.equal(video.copyPhoto, false);
  assert.equal(video["panel:selective"], false);
  // A host without a pasteboard offers no Copy Photo.
  assert.equal(menuState(editor({ backend: {} })).enabled.copyPhoto, false);
  // The library covers the photo.
  const library = menuState(editor({ libraryOpen: true })).enabled;
  assert.equal(library.export, false);
  assert.equal(library.open, true);
});

test("ticks follow the toolbar toggles and the open tab", () => {
  const { checked } = menuState(
    editor({ compare: true, histogram: true, panel: "develop" }),
  );
  assert.equal(checked.showOriginal, true);
  assert.equal(checked.histogram, true);
  assert.equal(checked["panel:develop"], true);
  assert.equal(checked["panel:film"], undefined);
  assert.deepEqual(MENU_PANELS, [
    "film",
    "light",
    "develop",
    "print",
    "selective",
    "crop",
  ]);
});

function withPlugins(list, overrides = {}) {
  const e = editor(overrides);
  e.plugins = {
    catalogue: [
      { id: "resolve", name: "DaVinci Resolve" },
      { id: "finalCut", name: "Final Cut Pro" },
    ],
    list,
    busy: null,
    install: (id) => e.calls.push(["install", id]),
    reveal: (id) => e.calls.push(["reveal", id]),
  };
  return e;
}

test("the Plugins menu installs in the dialog and reveals what is installed", () => {
  const e = withPlugins([
    { id: "resolve", state: "outdated", bundledVersion: "7", location: "/Library/OFX/Plugins/Fotufilm.ofx.bundle" },
    { id: "finalCut", state: "notInstalled", bundledVersion: "7" },
  ]);
  const { enabled, titles, toolTips } = menuState(e);
  assert.equal(titles["installPlugin:resolve"], "Reinstall DaVinci Resolve Plug-in…");
  assert.equal(titles["installPlugin:finalCut"], "Install Final Cut Pro Plug-in…");
  assert.equal(enabled["revealPlugin:resolve"], true);
  assert.equal(enabled["revealPlugin:finalCut"], false);
  assert.equal(toolTips["revealPlugin:resolve"], "/Library/OFX/Plugins/Fotufilm.ofx.bundle");
  assert.match(toolTips["revealPlugin:finalCut"], /not installed yet/);
  assert.ok(runCommand(e, "installPlugin:finalCut"));
  assert.ok(runCommand(e, "revealPlugin:resolve"));
  assert.equal(runCommand(e, "revealPlugin:finalCut"), false);
  assert.ok(runCommand(e, "plugins"));
  assert.deepEqual(e.calls, [
    ["dialog", "plugins"],
    ["install", "finalCut"],
    ["reveal", "resolve"],
    ["dialog", "plugins"],
  ]);
});

test("a plug-in this build lacks cannot be installed, and one install runs at a time", () => {
  const lacking = menuState(
    withPlugins([{ id: "finalCut", state: "notBundled" }]),
  );
  assert.equal(lacking.enabled["installPlugin:finalCut"], false);
  assert.match(lacking.toolTips["installPlugin:finalCut"], /does not contain/);
  const busy = withPlugins([{ id: "resolve", state: "notInstalled", bundledVersion: "7" }]);
  busy.plugins.busy = "finalCut";
  assert.equal(menuState(busy).enabled["installPlugin:resolve"], false);
  // A host without plug-ins has no such commands.
  assert.equal(menuState(editor()).enabled.plugins, false);
  assert.equal(runCommand(editor(), "installPlugin:resolve"), false);
});
