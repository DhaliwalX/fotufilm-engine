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
    photoView: {
      get: () => ({ zoom: 1, readout: 100 }),
      zoomIn: record("zoomIn"),
      zoomOut: record("zoomOut"),
      fit: record("fit"),
    },
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
    setCompare: record("compare"),
    setHistogram: record("histogram"),
    toggleFilms: record("films"),
    toggleInspector: record("toggleInspector"),
    editSettings: { copied: null, presets: [], sections: [] },
    pasteSettings: record("paste"),
    applyPreset: record("preset"),
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
  const e = editor({ history: { past: [], future: [] } });
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

test("Choose Film, Grain Model and Estimated Halation run on the loaded film", () => {
  const e = editor({
    stocks: [
      { id: "gold200", name: "Gold 200" },
      { id: "portra400", name: "Portra 400" },
    ],
    edit: { stock: "gold200", profile: {}, halationModel: "legacy" },
    selectStock: (id) => e.calls.push(["stock", id]),
    setProfile: (key, value) => e.calls.push(["profile", key, value]),
  });
  const state = menuState(e);
  assert.deepEqual(
    state.menus.films.map(([command]) => command),
    ["film:none", "film:gold200", "film:portra400"],
  );
  assert.equal(state.checked["film:gold200"], true);
  assert.equal(state.checked["grainModel:clump"], true);
  assert.equal(state.checked.estimatedHalation, false);
  assert.equal(runCommand(e, "film:portra400"), true);
  assert.equal(runCommand(e, "film:none"), true);
  assert.equal(runCommand(e, "grainModel:film"), true);
  assert.equal(runCommand(e, "estimatedHalation"), true);
  assert.deepEqual(e.calls, [
    ["stock", "portra400"],
    ["stock", null],
    ["profile", "grainModel", "film"],
    ["profile", "estimatedHalation", true],
  ]);
  // App-wide, as on the Mac: available with no photo or a fixed profile, where they set what new
  // photos start with and leave the open photo alone.
  const none = menuState({ ...e, active: null });
  assert.equal(none.enabled["grainModel:film"], true);
  assert.equal(none.checked["grainModel:clump"], true);
  assert.equal(none.enabled.estimatedHalation, true);
  const before = e.calls.length;
  assert.equal(
    runCommand({ ...e, fixedSettings: true }, "grainModel:film"),
    true,
  );
  assert.equal(e.calls.length, before);
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
    {
      id: "resolve",
      state: "outdated",
      bundledVersion: "7",
      location: "/Library/OFX/Plugins/Fotufilm.ofx.bundle",
    },
    { id: "finalCut", state: "notInstalled", bundledVersion: "7" },
  ]);
  const { enabled, titles, toolTips } = menuState(e);
  assert.equal(
    titles["installPlugin:resolve"],
    "Reinstall DaVinci Resolve Plug-in…",
  );
  assert.equal(
    titles["installPlugin:finalCut"],
    "Install Final Cut Pro Plug-in…",
  );
  assert.equal(enabled["revealPlugin:resolve"], true);
  assert.equal(enabled["revealPlugin:finalCut"], false);
  assert.equal(
    toolTips["revealPlugin:resolve"],
    "/Library/OFX/Plugins/Fotufilm.ofx.bundle",
  );
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
  const busy = withPlugins([
    { id: "resolve", state: "notInstalled", bundledVersion: "7" },
  ]);
  busy.plugins.busy = "finalCut";
  assert.equal(menuState(busy).enabled["installPlugin:resolve"], false);
  // A host without plug-ins has no such commands.
  assert.equal(menuState(editor()).enabled.plugins, false);
  assert.equal(runCommand(editor(), "installPlugin:resolve"), false);
});

test("Undo and Redo are named and the Edit History lists every step", () => {
  const opened = { stock: "gold200", rotation: 0 };
  const turned = { ...opened, rotation: 1 };
  const film = { ...turned, stock: "portra400" };
  const e = editor({
    stocks: [{ id: "gold200" }, { id: "portra400", name: "Portra 400" }],
    history: { past: [opened], present: turned, future: [film] },
  });
  const state = menuState(e);
  assert.deepEqual(state.titles, {
    undo: "Undo Crop & Rotate",
    redo: "Redo Portra 400",
    play: "Play",
  });
  // View › Play says what it will do next.
  assert.equal(menuState({ ...e, playing: true }).titles.play, "Pause");
  assert.deepEqual(state.history, ["Opened", "Crop & Rotate", "Portra 400"]);
  assert.equal(state.checked["history:1"], true);
  assert.equal(state.enabled["history:2"], true);
  assert.equal(state.enabled["history:3"], undefined);
  assert.ok(runCommand(e, "history:0"));
  assert.deepEqual(e.calls, [["dispatch", { type: "goTo", index: 0 }]]);
  assert.equal(runCommand(e, "history:3"), false);
  // With no photograph there is no history, and a covered photo's steps are greyed.
  assert.deepEqual(menuState(editor({ active: null })).history, []);
  assert.equal(
    menuState({ ...e, dialog: "export" }).enabled["history:0"],
    false,
  );
  const untouched = { past: [], present: opened, future: [] };
  assert.equal(menuState(editor({ history: untouched })).titles.undo, "Undo");
});

test("the Fotufilm menu offers Check for Updates where the host has a feed", () => {
  assert.equal(menuState(editor()).enabled.checkForUpdates, false);
  const state = menuState(editor({ checkForUpdates() {} }));
  assert.equal(state.enabled.checkForUpdates, true);
  assert.equal(state.checked.autoUpdates, true);
});

test("Copy Settings, Paste Settings and the presets run on the open photo", () => {
  const e = editor({
    editSettings: {
      copied: null,
      presets: [{ id: "p1", name: "Warm" }],
      sections: [],
    },
  });
  const state = menuState(e);
  assert.equal(state.enabled.copySettings, true);
  // Nothing copied yet.
  assert.equal(state.enabled.pasteSettings, false);
  assert.equal(runCommand(e, "pasteSettings"), false);
  assert.deepEqual(state.menus.presets, [["preset:p1", "Warm"]]);
  assert.equal(state.enabled.managePresets, true);
  assert.ok(runCommand(e, "copySettings"));
  assert.ok(runCommand(e, "preset:p1"));
  assert.ok(runCommand(e, "savePreset"));
  assert.deepEqual(e.calls, [
    ["dialog", "copySettings"],
    ["preset", "p1"],
    ["dialog", "savePreset"],
  ]);
  const copied = editor({
    editSettings: { copied: {}, presets: [], sections: [] },
  });
  assert.ok(runCommand(copied, "pasteSettings"));
  assert.equal(menuState(copied).enabled.managePresets, false);
  // Without a photo there is nothing to copy from or paste onto.
  const none = menuState(
    editor({
      active: null,
      editSettings: {
        copied: {},
        presets: [{ id: "p1", name: "Warm" }],
        sections: [],
      },
    }),
  ).enabled;
  assert.equal(none.copySettings, false);
  assert.equal(none.pasteSettings, false);
  assert.equal(none["preset:p1"], false);
});

test("the zoom items follow the canvas's view, which the editor never holds", () => {
  const at = (zoom) =>
    menuState(editor({ photoView: { get: () => ({ zoom, readout: 100 }) } }))
      .enabled;
  assert.deepEqual(
    [1, 2.5, 8].map((zoom) => {
      const { zoomIn, zoomOut, zoomToFit } = at(zoom);
      return [zoomIn, zoomOut, zoomToFit];
    }),
    [
      [true, false, false],
      [true, true, true],
      [false, true, true],
    ],
  );
  // Zoomed in, all three apply (at Fit, zooming out and fitting are refused).
  const e = editor();
  e.photoView = { ...e.photoView, get: () => ({ zoom: 2.5, readout: 100 }) };
  for (const command of ["zoomIn", "zoomOut", "zoomToFit"])
    runCommand(e, command);
  assert.deepEqual(e.calls, [["zoomIn"], ["zoomOut"], ["fit"]]);
});
