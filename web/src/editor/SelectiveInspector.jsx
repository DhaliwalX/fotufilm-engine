import SelectiveControls from "../SelectiveControls.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function SelectiveInspector() {
  const {
    exporting,
    active,
    edit,
    patch,
    endEdit,
    sampling,
    setSampling,
    showMask,
    setShowMask,
    shownResult,
  } = useEditor();
  return (
    <SelectiveControls
      disabled={exporting || !active}
      edit={edit}
      patch={patch}
      endEdit={endEdit}
      sampling={sampling}
      setSampling={setSampling}
      showMask={showMask}
      setShowMask={setShowMask}
      canSample={!!shownResult?.sceneSource}
    />
  );
}
