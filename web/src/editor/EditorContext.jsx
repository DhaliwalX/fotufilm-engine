import { createContext, useContext } from "react";
export const EditorContext = createContext(null);
export function useEditor() {
  const editor = useContext(EditorContext);
  if (!editor) throw new Error("Editor context is unavailable.");
  return editor;
}
