import { useBackend } from "../backend/BackendContext.jsx";
import useEditorState from "./useEditorState.js";
import usePreviewState from "./usePreviewState.js";
import useEditingActions from "./useEditingActions.js";
import useRendererLifecycle from "./useRendererLifecycle.js";
import usePreviewRenderer from "./usePreviewRenderer.js";
import usePipelineStages from "./usePipelineStages.js";
import useDocumentActions from "./useDocumentActions.js";
import useRollActions from "./useRollActions.js";
import useFilmActions from "./useFilmActions.js";
import useSettingsActions from "./useSettingsActions.js";
import useFilmPacks from "./useFilmPacks.js";
import useLibraryDocuments from "./useLibraryDocuments.js";
import useSavedEdits from "./useSavedEdits.js";
import useExportActions from "./useExportActions.js";
import useEditorShortcuts from "./useEditorShortcuts.js";
import useOutputState from "./useOutputState.js";
import useNativeCommands from "./useNativeCommands.js";
import useFilmSuggestion from "./useFilmSuggestion.js";
import usePlugins from "./usePlugins.js";
import useDocumentTitle from "./useDocumentTitle.js";
import useUpdates from "./useUpdates.js";
import { inspectorPanels } from "../editor-catalogue.js";
import { documentPanels } from "../negative-document.js";
export default function useEditorModel() {
  let editor = { backend: useBackend() };
  editor = {
    ...editor,
    ...useEditorState(editor),
  };
  editor = {
    ...editor,
    ...usePreviewState(editor),
  };
  editor = {
    ...editor,
    ...useEditingActions(editor),
  };
  editor = {
    ...editor,
    ...documentPanels(editor.edit, inspectorPanels, editor.panel),
  };
  editor = {
    ...editor,
    ...useRendererLifecycle(editor),
  };
  editor = {
    ...editor,
    ...usePreviewRenderer(editor),
  };
  editor = {
    ...editor,
    ...usePipelineStages(editor),
  };
  editor = {
    ...editor,
    ...useSavedEdits(editor),
  };
  editor = {
    ...editor,
    ...useDocumentActions(editor),
  };
  editor = {
    ...editor,
    ...useRollActions(editor),
  };
  editor = {
    ...editor,
    ...useFilmActions(editor),
  };
  editor = {
    ...editor,
    ...useSettingsActions(editor),
  };
  editor = {
    ...editor,
    ...useFilmPacks(editor),
  };
  editor = {
    ...editor,
    ...useLibraryDocuments(editor),
  };
  editor = {
    ...editor,
    ...useExportActions(editor),
  };
  editor = {
    ...editor,
    ...useEditorShortcuts(editor),
  };
  editor = {
    ...editor,
    ...useOutputState(editor),
  };
  editor = {
    ...editor,
    ...usePlugins(editor),
  };
  editor = {
    ...editor,
    ...useUpdates(editor),
  };
  useFilmSuggestion(editor);
  useNativeCommands(editor);
  useDocumentTitle(editor);
  return editor;
}
