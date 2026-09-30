const isTyping = (target) =>
  target instanceof HTMLElement &&
  (!!target.closest(
    "input, select, textarea, dialog, [role=dialog], [role=menu], [role=menuitem], [role=listbox], [role=option], [role=slider], [role=combobox], [role=switch]",
  ) ||
    target.isContentEditable);

import { useEffect, useRef } from "react";
export default function useEditorShortcuts({
  auto,
  exporting,
  openFiles,
  dispatch,
  active,
  setDialog,
  setCompare,
  setZoom,
  zoomIn,
  zoomOut,
  cropMode,
  setPanel,
  endEdit,
  setHistogram,
  setInspectorOpen,
  libraryOpen,
  setLibraryOpen,
  setShowNegative,
  editSettings,
  pasteSettings,
}) {
  // Pastes onto the edit standing when the key is pressed, not the one the listener was added on.
  const paste = useRef(pasteSettings);
  paste.current = pasteSettings;
  useEffect(() => {
    function keydown(event) {
      const command = event.metaKey || event.ctrlKey;
      if (command && event.shiftKey && event.key.toLowerCase() === "a") {
        if (!auto.available) return;
        event.preventDefault();
        if (isTyping(event.target)) event.target.blur();
        auto.toggle();
        return;
      }
      if (isTyping(event.target) || exporting) return;
      if (!command && event.key.toLowerCase() === "l") {
        setLibraryOpen((open) => !open);
        return;
      }
      if (libraryOpen) return;
      if (command && event.key.toLowerCase() === "o") {
        event.preventDefault();
        openFiles();
      } else if (command && event.key.toLowerCase() === "z") {
        event.preventDefault();
        dispatch({
          type: event.shiftKey ? "redo" : "undo",
        });
      } else if (command && event.altKey && event.code === "KeyN" && active) {
        // Show Negative (⌥⌘N); the code, since Option changes the character on a Mac.
        event.preventDefault();
        setShowNegative((shown) => !shown);
      } else if (command && event.altKey && event.code === "KeyC" && active) {
        event.preventDefault();
        setDialog("copySettings");
      } else if (command && event.altKey && event.code === "KeyV" && active) {
        event.preventDefault();
        if (editSettings.copied) paste.current();
      } else if (command && event.key.toLowerCase() === "s" && active) {
        event.preventDefault();
        setDialog("export");
      } else if (
        event.code === "Space" &&
        active &&
        !event.target.closest("button, [role=radio]")
      ) {
        event.preventDefault();
        setCompare(true);
      } else if (event.key === "Escape") {
        setCompare(false);
        setZoom(1);
        if (cropMode) setPanel("film");
      } else if (event.key === "Enter" && cropMode) {
        setPanel("film");
        endEdit();
      } else if (!command && event.key.toLowerCase() === "h")
        setHistogram((v) => !v);
      else if (!command && event.key.toLowerCase() === "c") {
        setPanel("crop");
        setInspectorOpen(true);
      } else if (event.key === "0") setZoom(1);
      else if (event.key === "+" || event.key === "=") zoomIn();
      else if (event.key === "-") zoomOut();
      else if (event.key === "Tab") return;
    }
    const release = (event) => {
      if (event.code === "Space") setCompare(false);
    };
    const blur = () => {
      setCompare(false);
      endEdit();
    };
    window.addEventListener("keydown", keydown);
    window.addEventListener("keyup", release);
    window.addEventListener("blur", blur);
    return () => {
      window.removeEventListener("keydown", keydown);
      window.removeEventListener("keyup", release);
      window.removeEventListener("blur", blur);
    };
  }, [
    openFiles,
    active,
    exporting,
    cropMode,
    endEdit,
    auto.available,
    auto.toggle,
    dispatch,
    libraryOpen,
    editSettings.copied,
  ]);
}
