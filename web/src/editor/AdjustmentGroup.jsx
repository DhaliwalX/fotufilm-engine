import { Adjustments } from "../Adjustment.jsx";
import { useEditor } from "./EditorContext.jsx";
// `hasFilm` false leaves out the film's scene-side controls.
export default function AdjustmentGroup({ group, hasFilm = true }) {
  const { active, edit, setParam, endEdit, exporting } = useEditor();
  return (
    <Adjustments
      group={group}
      hasFilm={hasFilm && !!edit.stock}
      params={edit.params}
      onChange={setParam}
      onEnd={endEdit}
      disabled={exporting || !active}
    />
  );
}
