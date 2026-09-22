import ProfileControls from "../ProfileControls.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function ProfileFields({ fields }) {
  const {
    active,
    exporting,
    fixedSettings,
    edit,
    selectedStock,
    setProfile,
    patch,
    endEdit,
  } = useEditor();
  return fixedSettings ? null : (
    <ProfileControls
      fields={fields}
      edit={edit}
      stock={selectedStock}
      onChange={setProfile}
      onReset={(field) => {
        const profile = {
          ...edit.profile,
        };
        delete profile[field];
        patch({
          profile,
        });
      }}
      onEnd={endEdit}
      disabled={exporting || !active || edit.halationModel === "layered"}
    />
  );
}
