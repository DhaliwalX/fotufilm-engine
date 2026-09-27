import { useEffect, useRef, useState } from "react";
import { inspectorPanels } from "../editor-catalogue.js";
import { appSetting, setAppSetting } from "../app-settings.js";
import { canShowNegative } from "../negative-view.js";
import { PLAYBACK_TOGGLE } from "../video-player/usePlayerShortcuts.js";
import { editHistory, filmNamer, redoTitle, undoTitle } from "../edit-history.js";
import { isFilmPack } from "./useFilmPacks.js";

// The native menu bar (cef/src/platform/mac) runs the editor's own handlers: the host sends
// "fotufilm-native-command" {command} and "fotufilm-native-open" {paths}, and the editor reports
// which commands apply now ("menuState") so the menus grey out and tick as its toolbars do, what
// Undo and Redo would undo ("titles") and the Edit History ("history", one title per step; the
// command "history:<step>" goes to a step). Film packs among the opened paths (File › Import Film
// Pack…, a Finder double-click) are installed.

// The inspector tabs in the order ⌘1…⌘6 choose them.
export const MENU_PANELS = [
  ...inspectorPanels.map((panel) => panel.id),
  "selective",
  "crop",
];

// The Plugins menu's two items per editor (cef/src/platform/mac/main_menu.mm), by plug-in id.
const PLUGIN_COMMAND = /^(installPlugin|revealPlugin):(.+)$/;

function pluginCommand(e, command) {
  const [, action, id] = PLUGIN_COMMAND.exec(command ?? "") ?? [];
  if (!action || !e.plugins) return undefined;
  // An install shows its progress and its answer in the plug-ins dialog.
  if (action === "installPlugin")
    return () => {
      e.setDialog("plugins");
      e.plugins.install(id);
    };
  return () => e.plugins.reveal(id);
}

// Install reads Reinstall once the plug-in is there, and each item says why it is grey, as the
// Mac app's Plugins menu does.
function pluginMenuState(e, enabled, titles, toolTips) {
  for (const { id, name } of e.plugins?.catalogue ?? []) {
    const status = e.plugins.list?.find((plugin) => plugin.id === id);
    const installed =
      !!status && status.state !== "notInstalled" && status.state !== "notBundled";
    const bundled = !!status?.bundledVersion;
    enabled[`installPlugin:${id}`] = bundled && !e.plugins.busy && !e.exporting;
    enabled[`revealPlugin:${id}`] = installed;
    titles[`installPlugin:${id}`] = `${installed ? "Reinstall" : "Install"} ${name} Plug-in…`;
    if (status && !bundled)
      toolTips[`installPlugin:${id}`] =
        `This copy of Fotufilm does not contain the ${name} plug-in.`;
    toolTips[`revealPlugin:${id}`] = installed
      ? status.location
      : `The ${name} plug-in is not installed yet. Choose Install ${name} Plug-in… first.`;
  }
}

const COMMANDS = {
  undo: (e) => e.dispatch({ type: "undo" }),
  redo: (e) => e.dispatch({ type: "redo" }),
  importNegative: (e) => e.setDialog("negative"),
  export: (e) => e.setDialog("export"),
  settings: (e) => e.setDialog("settings"),
  plugins: (e) => e.setDialog("plugins"),
  closePhoto: (e) => e.removeFile(e.active),
  autoAdjust: (e) => e.auto.toggle(),
  sampleSelection: (e) => {
    e.setInspector("selective");
    e.setSampling(true);
  },
  copyPhoto: (e) => e.copyPhoto(),
  resetEdits: (e) => e.resetEdits(),
  newGrainPattern: (e) => e.newGrainPattern(),
  autoFilm: () => setAppSetting("autoFilm", !appSetting("autoFilm")),
  forgetFilms: (e) => e.backend.forgetFilmChoices().catch(console.error),
  zoomIn: (e) => e.zoomIn(),
  zoomOut: (e) => e.zoomOut(),
  zoomToFit: (e) => e.setZoom(1),
  showOriginal: (e) => e.setCompare((shown) => !shown),
  histogram: (e) => e.setHistogram((shown) => !shown),
  showNegative: (e) => e.setShowNegative((shown) => !shown),
  play: () => window.dispatchEvent(new CustomEvent(PLAYBACK_TOGGLE)),
  estimatedHalation: (e) =>
    e.setProfile("estimatedHalation", e.edit.profile?.estimatedHalation !== true),
  filmSidebar: (e) => e.toggleFilms(),
  inspector: (e) => e.toggleInspector(),
  ...Object.fromEntries(
    MENU_PANELS.map((id) => [`panel:${id}`, (e) => e.setInspector(id)]),
  ),
};

const HISTORY = /^history:(\d+)$/;

// Commands with an argument: Film › Choose Film ("film:<id>", "film:none"), Film › Grain Model
// ("grainModel:<id>") and Edit › Edit History ("history:<step>").
function commandFor(command) {
  if (Object.hasOwn(COMMANDS, command ?? "")) return COMMANDS[command];
  const step = HISTORY.exec(command ?? "");
  if (step) return (e) => e.dispatch({ type: "goTo", index: Number(step[1]) });
  const [kind, value] = String(command).split(":");
  if (kind === "film" && value)
    return (e) => e.selectStock(value === "none" ? null : value);
  if (kind === "grainModel" && value)
    return (e) => e.setProfile("grainModel", value);
  return null;
}

// Which commands apply now and which are ticked, by the rules the toolbars use.
export function menuState(e) {
  // A dialog or the library covers the photo, as it does for the editor's own shortcuts.
  const free = !e.exporting && !e.libraryOpen && !e.dialog;
  const photo = free && !!e.active;
  const still = photo && !e.active.image.video;
  const enabled = {
    open: !e.exporting,
    importNegative: !e.exporting && !e.dialog,
    export: photo && e.stocks.length > 0,
    closePhoto: photo,
    undo: free && e.history.past.length > 0,
    redo: free && e.history.future.length > 0,
    autoAdjust: photo && e.auto.available,
    sampleSelection: still && !!e.shownResult,
    copyPhoto: still && !!e.backend.copyImage && !!e.session,
    resetEdits: photo,
    newGrainPattern: photo && !!e.edit?.stock,
    settings: true,
    plugins: !!e.plugins && !e.exporting,
    importFilmPack: !!e.filmPacks && !e.exporting,
    autoFilm: !!e.backend?.suggestFilm,
    forgetFilms: !!e.backend?.forgetFilmChoices,
    zoomIn: photo && !e.cropMode && e.zoom < 8,
    zoomOut: photo && !e.cropMode && e.zoom > 1,
    zoomToFit: photo && e.zoom !== 1,
    showOriginal: photo,
    histogram: photo,
    play: photo && !!e.active.image.video,
    showNegative:
      photo && canShowNegative(e.edit, e.stocks?.find(({ id }) => id === e.edit?.stock)),
    filmSidebar: !e.libraryOpen,
    inspector: !e.libraryOpen,
  };
  for (const id of MENU_PANELS)
    enabled[`panel:${id}`] =
      id === "selective" ? still : id === "crop" ? photo : !e.libraryOpen;
  const checked = {
    autoFilm: !!e.backend?.suggestFilm && appSetting("autoFilm") === true,
    autoAdjust: !!e.auto.active,
    showOriginal: !!e.compare,
    histogram: !!e.histogram,
    showNegative: !!e.showNegative,
    filmSidebar: !!e.filmOpen,
    inspector: !!e.inspectorOpen,
  };
  if (e.inspectorOpen) checked[`panel:${e.panel}`] = true;

  // The film list, and the film model of the one loaded, where its settings are not fixed.
  const films = [["film:none", "Normal"], ...e.stocks.map(({ id, name }) => [`film:${id}`, name])];
  for (const [command] of films) enabled[command] = photo;
  checked[`film:${e.edit?.stock ?? "none"}`] = true;
  const modelled = photo && !!e.edit?.stock && !e.fixedSettings;
  const grainModel = e.edit?.profile?.grainModel ?? "clump";
  for (const model of ["clump", "film"]) {
    enabled[`grainModel:${model}`] = modelled;
    checked[`grainModel:${model}`] = modelled && grainModel === model;
  }
  enabled.estimatedHalation = modelled && e.edit.halationModel !== "layered";
  checked.estimatedHalation = modelled && e.edit.profile?.estimatedHalation === true;

  // The Edit History of the photograph shown, as the Mac app's Edit menu lists it.
  const filmName = filmNamer(e.stocks);
  const history = e.active ? editHistory(e.history, filmName) : { titles: [], index: -1 };
  history.titles.forEach((_, step) => (enabled[`history:${step}`] = free));
  if (history.titles.length) checked[`history:${history.index}`] = true;
  const titles = {
      undo: undoTitle(e.history, filmName),
      redo: redoTitle(e.history, filmName),
    },
    toolTips = {};
  pluginMenuState(e, enabled, titles, toolTips);
  return { enabled, checked, titles, toolTips, history: history.titles, menus: { films } };
}

// Runs a menu command if it still applies; the host's copy of the state may be a frame old.
// Plug-in commands name their plug-in: "installPlugin:resolve", "revealPlugin:finalCut".
export function runCommand(editor, command) {
  const run = commandFor(command) ?? pluginCommand(editor, command);
  if (!run || !menuState(editor).enabled[command]) return false;
  run(editor);
  return true;
}

// Undo, Redo and the clipboard items belong to a focused text field rather than the photo.
const TEXT_FIELD =
  'textarea, [contenteditable]:not([contenteditable="false"]), input:not([type]), ' +
  "input[type=text], input[type=search], input[type=number], input[type=email], " +
  "input[type=url], input[type=password]";
const editsText = (element) =>
  element instanceof Element && element.matches(TEXT_FIELD);

export default function useNativeCommands(editor) {
  const transport = globalThis.window?.fotufilmNativeTransport;
  const latest = useRef(editor);
  latest.current = editor;
  const [textInput, setTextInput] = useState(false);
  const state = transport
    ? JSON.stringify({ ...menuState(editor), textInput })
    : null;

  useEffect(() => {
    if (!state) return;
    transport
      .postMessage({
        id: crypto.randomUUID(),
        method: "menuState",
        params: JSON.parse(state),
      })
      .catch(console.error);
  }, [transport, state]);

  useEffect(() => {
    if (!transport) return;
    // Read after the move, when activeElement names where focus landed.
    const focus = () =>
      queueMicrotask(() => setTextInput(editsText(document.activeElement)));
    const command = (event) => runCommand(latest.current, event.detail?.command);
    const open = (event) => {
      const paths = event.detail?.paths;
      if (!paths?.length) return;
      const items = paths.map((path) => ({ path, name: path.split("/").pop() }));
      if (items.some(({ name }) => !isFilmPack(name))) latest.current.setLibraryOpen(false);
      latest.current.acceptFiles(items);
    };
    document.addEventListener("focusin", focus);
    document.addEventListener("focusout", focus);
    window.addEventListener("fotufilm-native-command", command);
    window.addEventListener("fotufilm-native-open", open);
    // Files opened before the editor listened (a Finder double-click at launch) arrive now.
    transport
      .postMessage({ id: crypto.randomUUID(), method: "commandsReady" })
      .catch(console.error);
    return () => {
      document.removeEventListener("focusin", focus);
      document.removeEventListener("focusout", focus);
      window.removeEventListener("fotufilm-native-command", command);
      window.removeEventListener("fotufilm-native-open", open);
    };
  }, [transport]);
}
