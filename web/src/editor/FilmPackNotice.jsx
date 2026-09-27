import { AlertDialog } from "@react-spectrum/s2/AlertDialog";
import { useEditor } from "./EditorContext.jsx";

// What an import did, as the Mac app's alert says it: "Pack added" with the pack and its films,
// "Pack not added" and why, or that the pack needs a newer Fotufilm.
export default function FilmPackNotice() {
  const { packNotice } = useEditor();
  if (!packNotice) return null;
  return (
    <AlertDialog
      title={packNotice.title}
      variant={packNotice.added ? "confirmation" : "warning"}
      primaryActionLabel="OK"
    >
      <span className="film-pack-notice">{packNotice.message}</span>
    </AlertDialog>
  );
}
