import { EditorContext } from "./editor/EditorContext.jsx";
import useEditorModel from "./editor/useEditorModel.js";
import EditorWorkspace from "./editor/EditorWorkspace.jsx";
export default function App() {
  const editor = useEditorModel();
  return (
    <EditorContext.Provider value={editor}>
      <EditorWorkspace />
    </EditorContext.Provider>
  );
}
