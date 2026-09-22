const isTyping = (target) =>
  target instanceof HTMLElement &&
  (!!target.closest(
    "input, select, textarea, dialog, [role=dialog], [role=menu], [role=menuitem], [role=listbox], [role=option], [role=slider], [role=combobox], [role=switch]",
  ) ||
    target.isContentEditable);

import { useEffect } from "react";
export default function useEditorShortcuts({
  auto,
  exporting,
  openFiles,
  dispatch,
  active,
  setDialog,
  setCompare,
  setZoom,
  cropMode,
  setPanel,
  endEdit,
  setHistogram,
  setInspectorOpen,
}) {
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
      if (command && event.key.toLowerCase() === "o") {
        event.preventDefault();
        openFiles();
      } else if (command && event.key.toLowerCase() === "z") {
        event.preventDefault();
        dispatch({
          type: event.shiftKey ? "redo" : "undo",
        });
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
      else if (event.key === "+" || event.key === "=")
        setZoom((z) => Math.min(8, z + 0.25));
      else if (event.key === "-") setZoom((z) => Math.max(1, z - 0.25));
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
  ]);
}
