import { memo } from "react";
import { EditorContext, EditorFrameContext } from "./editor/EditorContext.jsx";
import useEditorModel from "./editor/useEditorModel.js";
import useStableEditor from "./editor/useStableEditor.js";
import EditorWorkspace from "./editor/EditorWorkspace.jsx";
// Renders again only for the contexts it reads, never because the model did.
const Workspace = memo(EditorWorkspace);
export default function App() {
  const { editor, frame } = useStableEditor(useEditorModel());
  return (
    <EditorContext.Provider value={editor}>
      <EditorFrameContext.Provider value={frame}>
        <Workspace />
      </EditorFrameContext.Provider>
    </EditorContext.Provider>
  );
}
