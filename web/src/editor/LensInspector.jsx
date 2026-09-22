import LensControls from "../LensControls.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function LensInspector() {
  const { active, edit, exporting, endEdit, patch, setStage, setDifference } =
    useEditor();
  return (
    <LensControls
      image={active?.image}
      lens={edit.lens}
      disabled={exporting || !active}
      onEnd={endEdit}
      onChange={(lens, group) => {
        patch(
          {
            lens,
          },
          group,
        );
        setStage(null);
        setDifference(false);
      }}
    />
  );
}
