import { useMemo } from "react";
import { DialogContainer } from "@react-spectrum/s2/Dialog";
import EditorToolbar from "./EditorToolbar.jsx";
import FilmLibrary from "./FilmLibrary.jsx";
import EditorViewer from "./EditorViewer.jsx";
import InspectorRail from "./InspectorRail.jsx";
import EditorInspector from "./EditorInspector.jsx";
import { IMAGE_ACCEPT } from "../media-types.js";
import { VIDEO_ACCEPT } from "../media-types.js";
import ExportDialog from "./ExportDialog.jsx";
import SavedExportNotice from "./SavedExportNotice.jsx";
import ShortcutsDialog from "./ShortcutsDialog.jsx";
import SupportDialog from "./SupportDialog.jsx";
import SettingsDialog from "./SettingsDialog.jsx";
import PluginsDialog from "./PluginsDialog.jsx";
import FilmPackNotice from "./FilmPackNotice.jsx";
import UpdateDialog from "./UpdateDialog.jsx";
import SettingsSectionsDialog from "./SettingsSectionsDialog.jsx";
import BandSetDialog from "./BandSetDialog.jsx";
import PresetsDialog from "./PresetsDialog.jsx";
import { FILM_PACK_EXTENSION } from "./useFilmPacks.js";
import { useEditor } from "./EditorContext.jsx";
import { PhotoLibrary } from "../photo-library/index.js";
import { libraryThumbnailRenderer } from "./libraryThumbnails.js";
import LibraryHandoff from "./LibraryHandoff.jsx";
import PanelResizer from "./PanelResizer.jsx";
import usePanelWidths from "./usePanelWidths.js";
export default function Workspace() {
  const {
    filmOpen,
    inspectorOpen,
    compactLayout,
    input,
    acceptFiles,
    editInput,
    restoreEdit,
    dialog,
    setDialog,
    libraryOpen,
    setLibraryOpen,
    openFromLibrary,
    libraryPhotoRenamed,
    libraryPhotosTrashed,
    filmPacks,
    packInput,
    importFilmPacks,
    importNegatives,
    backend,
    session,
    stocks,
  } = useEditor();
  const renderThumbnail = useMemo(
    () => libraryThumbnailRenderer({ backend, session, stocks }),
    [backend, session, stocks],
  );
  const { panelWidths, setPanelWidth, panelWidthStyle } = usePanelWidths();
  // Side panels resize beside the picture; the phone's stacked layout has no edges to drag.
  const resizable = !compactLayout;
  return (
    <div
      className={`editor ${filmOpen ? "" : "film-collapsed"} ${inspectorOpen ? "" : "inspector-collapsed"} ${libraryOpen ? "library-open" : ""}`}
      style={resizable ? panelWidthStyle : undefined}
    >
      <EditorToolbar />
      <div className="editor-panels" inert={libraryOpen}>
        <FilmLibrary />
        <EditorViewer />
        <InspectorRail />
        <EditorInspector />
        {resizable && filmOpen && (
          <PanelResizer side="film" width={panelWidths.film} onResize={setPanelWidth} />
        )}
        {resizable && inspectorOpen && (
          <PanelResizer
            side="inspector"
            width={panelWidths.inspector}
            onResize={setPanelWidth}
          />
        )}
      </div>
      <PhotoLibrary
        open={libraryOpen}
        onOpenPhotos={openFromLibrary}
        onPhotoRenamed={libraryPhotoRenamed}
        onPhotosTrashed={libraryPhotosTrashed}
        onClose={() => setLibraryOpen(false)}
        negatives={!!importNegatives}
        renderThumbnail={renderThumbnail}
      />
      <LibraryHandoff />
      <input
        ref={input}
        type="file"
        accept={`${IMAGE_ACCEPT},${VIDEO_ACCEPT}`}
        multiple
        hidden
        onChange={(e) => {
          // Files chosen as negatives open as scans.
          const negative = e.target.dataset.negative === "true";
          acceptFiles(
            negative ? [...e.target.files].map((file) => ({ file, negative })) : e.target.files,
          );
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
      {filmPacks && (
        <input
          ref={packInput}
          type="file"
          accept={FILM_PACK_EXTENSION}
          multiple
          hidden
          onChange={(e) => {
            importFilmPacks(Array.from(e.target.files)).catch(console.error);
            e.target.value = "";
          }}
        />
      )}
      <DialogContainer onDismiss={() => setDialog(null)}>
        {dialog === "export" ? (
          <ExportDialog />
        ) : dialog === "shortcuts" ? (
          <ShortcutsDialog />
        ) : dialog === "support" ? (
          <SupportDialog />
        ) : dialog === "settings" ? (
          <SettingsDialog />
        ) : dialog === "plugins" ? (
          <PluginsDialog />
        ) : dialog === "filmPack" ? (
          <FilmPackNotice />
        ) : dialog === "copySettings" ? (
          <SettingsSectionsDialog />
        ) : dialog === "savePreset" ? (
          <SettingsSectionsDialog preset />
        ) : dialog === "saveBands" ? (
          <BandSetDialog />
        ) : dialog === "presets" ? (
          <PresetsDialog />
        ) : dialog === "update" ? (
          <UpdateDialog />
        ) : null}
      </DialogContainer>
      <SavedExportNotice />
    </div>
  );
}
