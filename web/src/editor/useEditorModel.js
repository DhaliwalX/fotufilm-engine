import { useBackend } from "../backend/BackendContext.jsx";
import useEditorState from "./useEditorState.js";
import usePreviewState from "./usePreviewState.js";
import useEditingActions from "./useEditingActions.js";
import useRendererLifecycle from "./useRendererLifecycle.js";
import usePreviewRenderer from "./usePreviewRenderer.js";
import usePipelineStages from "./usePipelineStages.js";
import useDocumentActions from "./useDocumentActions.js";
import useFilmActions from "./useFilmActions.js";
import useLibraryDocuments from "./useLibraryDocuments.js";
import useExportActions from "./useExportActions.js";
import useEditorShortcuts from "./useEditorShortcuts.js";
import useOutputState from "./useOutputState.js";
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
    ...useDocumentActions(editor),
  };
  editor = {
    ...editor,
    ...useFilmActions(editor),
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
  return editor;
}
