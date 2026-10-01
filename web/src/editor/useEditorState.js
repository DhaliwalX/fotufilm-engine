import useCompactLayout from "../useCompactLayout.js";
import { useReducer, useState, useRef, useEffect } from "react";
import { historyReducer, initialHistory } from "../editor-state.js";
import { sourceIlluminant } from "../editor-catalogue.js";
import { setAppSetting, useAppSetting } from "../app-settings.js";
import { createPhotoView } from "../photo-view.js";
export default function useEditorState({}) {
  const compactLayout = useCompactLayout();
  const [history, historyDispatch] = useReducer(historyReducer, initialHistory);
  const edit = history.present;
  const [stocks, setStocks] = useState([]),
    [files, setFiles] = useState([]),
    [activeId, setActiveId] = useState(null);
  const active = files.find((file) => file.id === activeId);
  const sceneKelvin = sourceIlluminant(edit);
  const [panel, setPanel] = useState("film"),
    [filmOpen, setFilmOpen] = useState(() => !compactLayout),
    [inspectorOpen, setInspectorOpen] = useState(() => !compactLayout);
  useEffect(() => {
    if (compactLayout) {
      setFilmOpen(false);
      setInspectorOpen(false);
    }
  }, [compactLayout]);
  const [search, setSearch] = useState(""),
    // The canvas owns the photograph's view; the editor steps it through this handle.
    [photoView] = useState(createPhotoView),
    [compare, setCompare] = useState(false);
  const [histogram, setHistogram] = useState(false),
    [dragOver, setDragOver] = useState(false);
  const [result, setResult] = useState(null),
    [status, setStatus] = useState("Loading films"),
    [error, setError] = useState(null),
    [libraryError, setLibraryError] = useState(null),
    [importStatus, setImportStatus] = useState(null);
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [dialog, setDialog] = useState(null),
    [exporting, setExporting] = useState(false),
    [exportType, setExportType] = useState("image/png"),
    [exportSize, setExportSize] = useState("full"),
    [quality, setQuality] = useState(95),
    // The Mac app's default: capture details without location.
    [exportMetadata, setExportMetadata] = useState("preserveWithoutLocation");
  // HDR is the Photos output setting, kept on this device.
  const exportHDR = useAppSetting("photoHDR"),
    setExportHDR = (value) => setAppSetting("photoHDR", value);
  const [stage, setStage] = useState(null),
    [stages, setStages] = useState([]),
    [difference, setDifference] = useState(false),
    // View › Show Negative: a way of looking, not part of the edit.
    [showNegative, setShowNegative] = useState(false);
  const [session, setSession] = useState(null),
    [retry, setRetry] = useState(0);
  const input = useRef(null),
    editInput = useRef(null),
    histories = useRef(new Map()),
    urls = useRef(new Set()),
    loadGeneration = useRef(0),
    importController = useRef(null);
  const [videoTime, setVideoTime] = useState(0),
    [videoFormat, setVideoFormat] = useState("mp4"),
    [videoQuality, setVideoQuality] = useState("high"),
    [savedExport, setSavedExport] = useState(null);
  const videoExportController = useRef(null),
    imageResources = useRef(new Set()),
    savedExportRef = useRef(null);
  const [sampling, setSampling] = useState(false);
  const [showMask, setShowMask] = useState(false);
  useEffect(() => {
    setSampling(false);
    setShowMask(false);
  }, [activeId]);
  return {
    compactLayout,
    history,
    historyDispatch,
    edit,
    stocks,
    setStocks,
    files,
    setFiles,
    activeId,
    setActiveId,
    active,
    sceneKelvin,
    panel,
    setPanel,
    filmOpen,
    setFilmOpen,
    inspectorOpen,
    setInspectorOpen,
    search,
    setSearch,
    photoView,
    compare,
    setCompare,
    histogram,
    setHistogram,
    dragOver,
    setDragOver,
    result,
    setResult,
    status,
    setStatus,
    error,
    setError,
    libraryError,
    setLibraryError,
    importStatus,
    setImportStatus,
    libraryOpen,
    setLibraryOpen,
    dialog,
    setDialog,
    exporting,
    setExporting,
    exportType,
    setExportType,
    exportSize,
    setExportSize,
    quality,
    setQuality,
    exportMetadata,
    setExportMetadata,
    exportHDR,
    showNegative,
    setShowNegative,
    setExportHDR,
    stage,
    setStage,
    stages,
    setStages,
    difference,
    setDifference,
    session,
    setSession,
    retry,
    setRetry,
    input,
    editInput,
    histories,
    urls,
    loadGeneration,
    importController,
    videoTime,
    setVideoTime,
    videoFormat,
    setVideoFormat,
    videoQuality,
    setVideoQuality,
    savedExport,
    setSavedExport,
    videoExportController,
    imageResources,
    savedExportRef,
    sampling,
    setSampling,
    showMask,
    setShowMask,
  };
}
