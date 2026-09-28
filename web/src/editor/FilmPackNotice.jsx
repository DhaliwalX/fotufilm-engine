import { AlertDialog } from "@react-spectrum/s2/AlertDialog";
import { useEditor } from "./EditorContext.jsx";

// What an import did, as the Mac app's alert says it: "Pack added" with the pack and its films,
// "Pack not added" and why, or that the pack needs a newer Fotufilm.
export default function FilmPackNotice() {
  const { packNotice, checkForUpdates } = useEditor();
  if (!packNotice) return null;
  // A pack that needs a newer Fotufilm offers the update, as the Mac app's alert does.
  const offerUpdate = packNotice.update === true && !!checkForUpdates;
  return (
    <AlertDialog
      title={packNotice.title}
      variant={packNotice.added ? "confirmation" : "warning"}
      primaryActionLabel={offerUpdate ? "Check for Updates…" : "OK"}
      cancelLabel={offerUpdate ? "Later" : undefined}
      onPrimaryAction={offerUpdate ? checkForUpdates : undefined}
    >
      <span className="film-pack-notice">{packNotice.message}</span>
    </AlertDialog>
  );
}
