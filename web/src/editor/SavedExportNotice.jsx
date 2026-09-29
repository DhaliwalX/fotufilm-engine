import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { VIDEO_LABELS } from "../generated/controls.js";
import { useEditor } from "./EditorContext.jsx";

// What an export just saved: a download link where the browser holds the file, and where the
// host saved it to disk, Open (the system's viewer for it) and the host's Show in Finder.
export default function SavedExportNotice() {
  const { backend, savedExport, savedExportRef, setSavedExport, setError } = useEditor();
  if (!savedExport) return null;
  const openable = backend.openExport && savedExport.path;
  const open = (reveal) =>
    backend.openExport(savedExport.path, { reveal }).catch((error) => setError(error.message));
  return (
    <div className="saved-export" role="status">
      {savedExport.url ? (
        <a href={savedExport.url} download={savedExport.filename}>
          Download {savedExport.filename}
        </a>
      ) : (
        <span>Saved {savedExport.filename}</span>
      )}
      {openable && (
        <>
          {/* Export All saved many files: only their folder is shown. */}
          {!savedExport.count && (
            <ActionButton onPress={() => open(false)} size={"S"}>
              Open
            </ActionButton>
          )}
          <ActionButton onPress={() => open(true)} size={"S"}>
            {backend.revealExportLabel ?? "Show File"}
          </ActionButton>
        </>
      )}
      <ActionButton
        onPress={async () => {
          await savedExport.dispose?.();
          savedExportRef.current = null;
          setSavedExport(null);
        }}
        size={"S"}
      >
        {VIDEO_LABELS.dismiss}
      </ActionButton>
    </div>
  );
}
