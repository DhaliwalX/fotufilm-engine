import SourceInterpretationControls from "../SourceInterpretationControls.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function SourceInspector() {
  const { active, edit, exporting, endEdit, patch, setStage, setDifference } =
    useEditor();
  return (
    <SourceInterpretationControls
      image={active?.image}
      value={edit.sourceInterpretation}
      disabled={exporting}
      onChange={(sourceInterpretation) => {
        endEdit();
        patch({
          sourceInterpretation,
        });
        setStage(null);
        setDifference(false);
      }}
    />
  );
}
