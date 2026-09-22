import CropControls from "../CropControls.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function CropInspector() {
  const {
    edit,
    width,
    height,
    cropSize,
    exporting,
    active,
    patch,
    endEdit,
    setPanel,
  } = useEditor();
  return (
    <CropControls
      edit={edit}
      width={width}
      height={height}
      size={cropSize}
      disabled={exporting || !active}
      patch={patch}
      onEnd={endEdit}
      onDone={() => {
        endEdit();
        setPanel("film");
      }}
    />
  );
}
