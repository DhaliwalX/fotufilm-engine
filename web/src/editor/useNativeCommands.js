import { useEffect, useRef, useState } from "react";
import { inspectorPanels } from "../editor-catalogue.js";

// The native menu bar (cef/src/platform/mac) runs the editor's own handlers: the host sends
// "fotufilm-native-command" {command} and "fotufilm-native-open" {paths}, and the editor reports
// which commands apply now ("menuState") so the menus grey out and tick as its toolbars do.

// The inspector tabs in the order ⌘1…⌘6 choose them.
export const MENU_PANELS = [
  ...inspectorPanels.map((panel) => panel.id),
  "selective",
  "crop",
];

const COMMANDS = {
  undo: (e) => e.dispatch({ type: "undo" }),
  redo: (e) => e.dispatch({ type: "redo" }),
  importNegative: (e) => e.setDialog("negative"),
  export: (e) => e.setDialog("export"),
  closePhoto: (e) => e.removeFile(e.active),
  autoAdjust: (e) => e.auto.toggle(),
  sampleSelection: (e) => {
    e.setInspector("selective");
    e.setSampling(true);
  },
  copyPhoto: (e) => e.copyPhoto(),
  resetEdits: (e) => e.resetEdits(),
  newGrainPattern: (e) => e.newGrainPattern(),
  zoomIn: (e) => e.zoomIn(),
  zoomOut: (e) => e.zoomOut(),
  zoomToFit: (e) => e.setZoom(1),
  showOriginal: (e) => e.setCompare((shown) => !shown),
  histogram: (e) => e.setHistogram((shown) => !shown),
  filmSidebar: (e) => e.toggleFilms(),
  inspector: (e) => e.toggleInspector(),
  ...Object.fromEntries(
    MENU_PANELS.map((id) => [`panel:${id}`, (e) => e.setInspector(id)]),
  ),
};

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
    zoomIn: photo && !e.cropMode && e.zoom < 8,
    zoomOut: photo && !e.cropMode && e.zoom > 1,
    zoomToFit: photo && e.zoom !== 1,
    showOriginal: photo,
    histogram: photo,
    filmSidebar: !e.libraryOpen,
    inspector: !e.libraryOpen,
  };
  for (const id of MENU_PANELS)
    enabled[`panel:${id}`] =
      id === "selective" ? still : id === "crop" ? photo : !e.libraryOpen;
  const checked = {
    autoAdjust: !!e.auto.active,
    showOriginal: !!e.compare,
    histogram: !!e.histogram,
    filmSidebar: !!e.filmOpen,
    inspector: !!e.inspectorOpen,
  };
  if (e.inspectorOpen) checked[`panel:${e.panel}`] = true;
  return { enabled, checked };
}

// Runs a menu command if it still applies; the host's copy of the state may be a frame old.
export function runCommand(editor, command) {
  const run = COMMANDS[command];
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
      latest.current.setLibraryOpen(false);
      latest.current.acceptFiles(
        paths.map((path) => ({ path, name: path.split("/").pop() })),
      );
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
