import { createContext, useContext } from "react";
export const EditorContext = createContext(null);
// What changes with every frame of a playing movie (`useStableEditor.js`): only the components
// that show it read it here, so the rest of the editor is not rendered again for every frame.
export const EditorFrameContext = createContext(null);
export function useEditor() {
  const editor = useContext(EditorContext);
  if (!editor) throw new Error("Editor context is unavailable.");
  return editor;
}
export function useEditorFrame() {
  const frame = useContext(EditorFrameContext);
  if (!frame) throw new Error("Editor frame context is unavailable.");
  return frame;
}
