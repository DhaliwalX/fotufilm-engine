import { withProfileField } from "../profile-settings.js";
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
      onReset={(field) =>
        patch({ profile: withProfileField(edit.profile, field, undefined) })
      }
      onEnd={endEdit}
      disabled={exporting || !active}
    />
  );
}
