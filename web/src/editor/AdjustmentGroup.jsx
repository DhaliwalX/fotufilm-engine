import { Adjustments } from "../Adjustment.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function AdjustmentGroup({ group }) {
  const { active, edit, setParam, endEdit, exporting } = useEditor();
  return (
    <Adjustments
      group={group}
      hasFilm={!!edit.stock}
      params={edit.params}
      onChange={setParam}
      onEnd={endEdit}
      disabled={exporting || !active}
    />
  );
}
