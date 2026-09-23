import { DialogContainer } from "@react-spectrum/s2/Dialog";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import EditorToolbar from "./EditorToolbar.jsx";
import FilmLibrary from "./FilmLibrary.jsx";
import EditorViewer from "./EditorViewer.jsx";
import InspectorRail from "./InspectorRail.jsx";
import EditorInspector from "./EditorInspector.jsx";
import { IMAGE_ACCEPT } from "../media-types.js";
import { VIDEO_ACCEPT } from "../media-types.js";
import NegativeImportDialog from "../NegativeImportDialog.jsx";
import { useNegativeImportDialog } from "./useNegativeImportDialog.js";
import ExportDialog from "./ExportDialog.jsx";
import { VIDEO_LABELS } from "../generated/controls.js";
import ShortcutsDialog from "./ShortcutsDialog.jsx";
import SupportDialog from "./SupportDialog.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function Workspace() {
  const {
    filmOpen,
    inspectorOpen,
    input,
    acceptFiles,
    editInput,
    restoreEdit,
    dialog,
    setDialog,
    videoDownload,
    videoDownloadRef,
    setVideoDownload,
  } = useEditor();
  const negative = useNegativeImportDialog();
  return (
    <div
      className={`editor ${filmOpen ? "" : "film-collapsed"} ${inspectorOpen ? "" : "inspector-collapsed"}`}
    >
      <EditorToolbar />
      <FilmLibrary />
      <EditorViewer />
      <InspectorRail />
      <EditorInspector />
      <input
        ref={input}
        type="file"
        accept={`${IMAGE_ACCEPT},${VIDEO_ACCEPT}`}
        multiple
        hidden
        onChange={(e) => {
          acceptFiles(e.target.files);
          e.target.value = "";
        }}
      />
      <input
        ref={editInput}
        type="file"
        accept=".json"
        hidden
        onChange={(e) => {
          restoreEdit(e.target.files?.[0]);
          e.target.value = "";
        }}
      />
      <DialogContainer onDismiss={() => setDialog(null)}>
        {dialog === "negative" ? (
          <NegativeImportDialog
            onClose={() => setDialog(null)}
            model={negative}
          />
        ) : dialog === "export" ? (
          <ExportDialog />
        ) : dialog === "shortcuts" ? (
          <ShortcutsDialog />
        ) : dialog === "support" ? (
          <SupportDialog />
        ) : null}
      </DialogContainer>
      {videoDownload && (
        <div className="video-download" role="status">
          {videoDownload.url ? (
            <a href={videoDownload.url} download={videoDownload.filename}>
              Download {videoDownload.filename}
            </a>
          ) : (
            <span>Saved {videoDownload.filename}</span>
          )}
          <ActionButton
            onPress={async () => {
              await videoDownload.dispose();
              videoDownloadRef.current = null;
              setVideoDownload(null);
            }}
            size={"S"}
          >
            {VIDEO_LABELS.dismiss}
          </ActionButton>
        </div>
      )}
    </div>
  );
}
