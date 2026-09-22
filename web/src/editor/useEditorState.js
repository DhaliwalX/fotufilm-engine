import useCompactLayout from "../useCompactLayout.js";
import { useReducer, useState, useRef, useEffect } from "react";
import { historyReducer, initialHistory } from "../editor-state.js";
import { sourceIlluminant } from "../editor-catalogue.js";
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
    [zoom, setZoom] = useState(1),
    [compare, setCompare] = useState(false);
  const [histogram, setHistogram] = useState(false),
    [dragOver, setDragOver] = useState(false);
  const [result, setResult] = useState(null),
    [status, setStatus] = useState("Loading films"),
    [error, setError] = useState(null),
    [libraryError, setLibraryError] = useState(null),
    [importStatus, setImportStatus] = useState(null);
  const [dialog, setDialog] = useState(null),
    [exporting, setExporting] = useState(false),
    [exportType, setExportType] = useState("image/png"),
    [exportSize, setExportSize] = useState("full"),
    [quality, setQuality] = useState(95);
  const [stage, setStage] = useState(null),
    [stages, setStages] = useState([]),
    [difference, setDifference] = useState(false);
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
    [videoDownload, setVideoDownload] = useState(null);
  const videoExportController = useRef(null),
    clips = useRef(new Set()),
    videoDownloadRef = useRef(null);
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
    zoom,
    setZoom,
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
    videoDownload,
    setVideoDownload,
    videoExportController,
    clips,
    videoDownloadRef,
    sampling,
    setSampling,
    showMask,
    setShowMask,
  };
}
