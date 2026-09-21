import { preferredCanvasColorSpace, colorSpaceLabel } from "./canvas-color.js";
import { usePreviewQuality } from "./usePreviewQuality.js";
import CropControls from "./CropControls.jsx";
import PrintFrameControls from "./PrintFrameControls.jsx";
import { usePrintFrame } from "./usePrintFrame.js";
import { frameSamplePoint } from "./print-frame.js";
import { useAutoAdjustment } from "./useAutoAdjustment.js";
import AutoAdjustmentAction from "./AutoAdjustmentAction.jsx";
import { useLensCatalogue } from "./useLensCatalogue.js";
import NegativeImportDialog from "./NegativeImportDialog.jsx";
import { importPhoto } from "./photo-import.js";
import SourceInterpretationControls from "./SourceInterpretationControls.jsx";
import LensControls from "./LensControls.jsx";
import InspectorPanel from "./InspectorPanel.jsx";
import LensFilters from "./LensFilters.jsx";
import ProfileControls from "./ProfileControls.jsx";
import { hasProfileSettings, profileMedium } from "./profile-settings.js";
import SelectiveControls from "./SelectiveControls.jsx";
import { newSelection, sampleScene } from "./selective.js";
import {
  editorControl,
  inspectorPanels,
  sourceIlluminant,
} from "./editor-catalogue.js";
import {
  VIDEO_LABELS,
  SCREEN_CONVERSION,
  FILM_FORMATS,
} from "./generated/controls.js";
import VideoControls from "./VideoControls.jsx";
import { VIDEO_ACCEPT, isVideoFile, importVideo } from "./video-import.js";
import {
  createVideoDestination,
  exportVideo,
  videoDimensions,
} from "./video-export.js";
import { Button } from "@astryxdesign/core/Button";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Switch } from "@astryxdesign/core/Switch";
import { TabList, Tab } from "@astryxdesign/core/TabList";
import { Selector } from "@astryxdesign/core/Selector";
import { PreviewQueue, previewLabel } from "./preview-queue.js";
import { IMAGE_ACCEPT, isRawFile, importRaw } from "./raw-import.js";
import { isEXRFile, importEXR } from "./exr-import.js";
import { assetUrl } from "./engine.js";
import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import { RenderSession, loadStockIndex } from "./render-session.js";
import {
  defaultEdit,
  fullCrop,
  historyReducer,
  initialHistory,
  parseEdit,
} from "./editor-state.js";
import { exportTiff } from "./tiff-export.js";
import { canvasBlob, outputSize } from "./geometry.js";
import {
  Adjustment,
  Adjustments,
  Icon,
  ImageCanvas,
  Modal,
  Section,
  ToolButton,
} from "./EditorControls.jsx";

const stageNames = [
  "Bypass",
  "Exposure",
  "Flare",
  "Diffusion",
  "Halation",
  "Couplers",
  "Development",
  "Grain",
  "Negative",
  "Output",
];
const isTyping = (target) =>
  target instanceof HTMLElement &&
  (!!target.closest(
    "input, select, textarea, dialog, [role=slider], [role=combobox], [role=switch]",
  ) ||
    target.isContentEditable);
const cleanName = (name) =>
  name
    .replace(/\.[^.]+$/, "")
    .replace(/[^\p{L}\p{N}_-]+/gu, "-")
    .slice(0, 100) || "photo";
function download(blob, name) {
  const url = URL.createObjectURL(blob),
    link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
function StockRow({ stock, active, image, session, onSelect }) {
  const ref = useRef(null),
    [url, setUrl] = useState(null);
  useEffect(() => {
    if (!image || !session) return;
    let cancelled = false,
      objectUrl;
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      // Wait until the main preview has been queued before thumbnail work.
      timer = setTimeout(
        () =>
          session
            .render({
              image,
              stock: stock.id,
              edit: defaultEdit(stock.id),
              maxEdge: 160,
              background: true,
              stale: () => cancelled,
            })
            .then((result) => {
              if (!result || cancelled) return;
              objectUrl = URL.createObjectURL(result.blob);
              setUrl(objectUrl);
            })
            .catch(() => {}),
        400,
      );
    });
    let timer;
    observer.observe(ref.current);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      observer.disconnect();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      setUrl(null);
    };
  }, [image, session, stock.id]);
  return (
    <button
      ref={ref}
      className={`stock-row ${active ? "selected" : ""}`}
      aria-pressed={active}
      onClick={onSelect}
      title={stock.name}
    >
      <span className="stock-thumb">
        {url ? <img src={url} alt="" /> : <Icon name="film" />}
      </span>
      <span className="stock-copy">
        <span>{stock.name}</span>
        <small>{stock.kind || "Film"}</small>
      </span>
      {active && <Icon name="check" />}
    </button>
  );
}

export default function App() {
  const [history, historyDispatch] = useReducer(historyReducer, initialHistory);
  const edit = history.present;
  const [stocks, setStocks] = useState([]),
    [files, setFiles] = useState([]),
    [activeId, setActiveId] = useState(null);
  const active = files.find((file) => file.id === activeId);
  const sceneKelvin = sourceIlluminant(edit);
  const [panel, setPanel] = useState("film"),
    [filmOpen, setFilmOpen] = useState(() => window.innerWidth >= 834),
    [inspectorOpen, setInspectorOpen] = useState(
      () => window.innerWidth >= 834,
    );
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
  const cropMode = panel === "crop" && inspectorOpen;
  const [zoomReadout, setZoomReadout] = useState(100);
  const previewEditJSON = JSON.stringify(
    cropMode ? { ...edit, crop: fullCrop(), ratio: "free" } : edit,
  );
  const [viewerMoving, setViewerMoving] = useState(false);
  const [detailBackend, setDetailBackend] = useState(null);
  const editInteractionKey = JSON.stringify([
    activeId,
    previewEditJSON,
    stage,
    difference,
    cropMode,
    showMask,
    videoTime,
  ]);
  const interactionKey = JSON.stringify([editInteractionKey, zoom]);
  const interacting = usePreviewQuality(
    interactionKey,
    !!history.group || viewerMoving,
  );
  const previewInteracting = usePreviewQuality(
    editInteractionKey,
    !!history.group,
  );
  const [interactiveEdge, setInteractiveEdge] = useState(512);
  const previewEdge = Math.min(
    Math.max(
      active?.image.naturalWidth || 1600,
      active?.image.naturalHeight || 1600,
    ),
    previewInteracting ? interactiveEdge : 1600,
  );
  const lensCatalogue = useLensCatalogue();
  const previewKey = JSON.stringify([
    lensCatalogue.revision,
    activeId,
    active?.image.video ? videoTime : null,
    previewEditJSON,
    stage,
    difference,
    cropMode,
    previewEdge,
    showMask,
  ]);
  const previewEdit = useMemo(
    () => JSON.parse(previewEditJSON),
    [previewEditJSON],
  );
  const detailRequest = useMemo(
    () =>
      active
        ? {
            image: active.image,
            videoTime,
            edit: previewEdit,
            stock: previewEdit.stock || stocks[0]?.id || "normal",
            stage,
            difference,
            cropMode,
            showMask,
          }
        : null,
    [
      active,
      videoTime,
      previewEdit,
      stocks,
      stage,
      difference,
      cropMode,
      showMask,
      retry,
    ],
  );
  const selectedStock = stocks.find((stock) => stock.id === edit.stock);
  const stockId = edit.stock || stocks[0]?.id || "normal";
  const visibleError = error || libraryError;
  const auto = useAutoAdjustment({
    image: active?.image,
    session,
    history,
    dispatch: historyDispatch,
    disabled: exporting,
    onError: setError,
    onApplied: () => {
      setStage(null);
      setDifference(false);
    },
  });
  const dispatch = auto.dispatch;
  const patch = useCallback(
    (value, group) => dispatch({ type: "edit", patch: value, group }),
    [dispatch],
  );
  const endEdit = useCallback(() => dispatch({ type: "end" }), [dispatch]);
  const setProfile = (key, value) => {
    patch({ profile: { ...edit.profile, [key]: value } }, `profile-${key}`);
    setStage(null);
    setDifference(false);
  };
  const profileControls = (fields) => (
    <ProfileControls
      fields={fields}
      edit={edit}
      stock={selectedStock}
      onChange={setProfile}
      onReset={(field) => {
        const profile = { ...edit.profile };
        delete profile[field];
        patch({ profile });
      }}
      onEnd={endEdit}
      disabled={exporting || !active || edit.halationModel === "layered"}
    />
  );
  const setParam = (key, value) =>
    patch({ params: { ...edit.params, [key]: value } }, key);
  const setInspector = (value) => {
    endEdit();
    setPanel(value);
    setSampling(false);
    setShowMask(false);
    if (value === "selective") {
      setStage(null);
      setDifference(false);
    }
    setInspectorOpen(true);
    if (window.innerWidth < 834) setFilmOpen(false);
    setCompare(false);
  };

  const alive = useRef(false);
  const previewQueue = useRef(null);
  const lastRenderedPreview = useRef(null);
  const currentPreview = useRef(null);
  currentPreview.current = {
    activeId,
    key: previewKey,
    exporting,
    cropMode,
    interacting,
    previewInteracting,
    interactionKey,
  };
  useEffect(() => {
    const renderer = new RenderSession();
    renderer.onRendererReady = () => {
      if (alive.current) setRetry((value) => value + 1);
    };
    alive.current = true;
    previewQueue.current = new PreviewQueue((text) => {
      if (alive.current && !currentPreview.current?.exporting) setStatus(text);
    });
    setSession(renderer);
    return () => {
      alive.current = false;
      previewQueue.current.close();
      renderer.dispose();
      videoExportController.current?.abort();
      videoDownloadRef.current?.dispose();
      for (const clip of clips.current) clip.dispose();
      clips.current.clear();
      importController.current?.abort();
      loadGeneration.current++;
      for (const url of urls.current) URL.revokeObjectURL(url);
      urls.current.clear();
    };
  }, []);
  useEffect(() => {
    let cancelled = false;
    setLibraryError(null);
    setStatus("Loading films");
    loadStockIndex()
      .then((index) => {
        if (!cancelled) {
          setStocks(index);
          setStatus(null);
        }
      })
      .catch((e) => {
        if (!cancelled) {
          setLibraryError(e.message);
          setStatus(null);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [retry]);
  useEffect(() => {
    if (activeId) histories.current.set(activeId, history);
  }, [history, activeId]);

  const replaceResult = useCallback((next) => {
    setResult((previous) => {
      for (const url of [previous?.url, previous?.originalUrl])
        if (url) {
          URL.revokeObjectURL(url);
          urls.current.delete(url);
        }
      return next;
    });
  }, []);
  useEffect(() => {
    if (!active || !stockId || !session || exporting) return;
    const currentFile = () =>
      alive.current && currentPreview.current?.activeId === active.id;
    const request = {
      image: active.image,
      videoTime,
      edit: previewEdit,
      showMask,
      stock: stockId,
      maxEdge: previewEdge,
      stage,
      difference,
      cropMode,
      stale: () =>
        !currentFile() ||
        currentPreview.current.exporting ||
        currentPreview.current.cropMode !== cropMode ||
        (!previewInteracting &&
          (currentPreview.current.previewInteracting ||
            currentPreview.current.key !== previewKey)),
    };
    const frame = requestAnimationFrame(() => {
      const stock = stocks.find((item) => item.id === previewEdit.stock);
      const queued = {
        fileId: active.id,
        filename: active.name,
        edit: previewEdit,
        stockName: stock?.name,
        mediumName: stock?.media.find(
          (medium) => medium.id === previewEdit.medium,
        )?.name,
        edge: previewEdge,
        cropMode,
        stage,
        difference,
        stageLabel: stages[stage]?.label,
      };
      const label = previewLabel(queued, lastRenderedPreview.current);
      previewQueue.current
        .submit(
          (onProgress) => session.render({ ...request, onProgress }),
          label,
        )
        .then((next) => {
          if (
            !next ||
            !currentFile() ||
            currentPreview.current.exporting ||
            currentPreview.current.cropMode !== cropMode ||
            request.stale()
          )
            return;
          if (previewInteracting) {
            if (next.renderMilliseconds > 65)
              setInteractiveEdge((edge) =>
                Math.max(256, Math.round(edge * 0.8)),
              );
            else if (next.renderMilliseconds < 25)
              setInteractiveEdge((edge) =>
                Math.min(800, Math.round(edge * 1.1)),
              );
          }
          const url = URL.createObjectURL(next.blob),
            originalUrl = URL.createObjectURL(next.original);
          urls.current.add(url);
          urls.current.add(originalUrl);
          replaceResult({
            ...next,
            url,
            originalUrl,
            key: previewKey,
            fileId: active.id,
            stock: previewEdit.stock,
            stage,
          });
          lastRenderedPreview.current = queued;
          setError(null);
        })
        .catch((error) => {
          if (currentFile()) {
            setError(error.message);
            if (!previewQueue.current.running) setStatus(null);
          }
        });
    });
    return () => cancelAnimationFrame(frame);
  }, [
    active,
    videoTime,
    previewEdit,
    previewEdge,
    previewInteracting,
    previewKey,
    stockId,
    session,
    stage,
    difference,
    cropMode,
    exporting,
    retry,
    replaceResult,
  ]);

  useEffect(() => {
    if (panel !== "pipeline" || !session || !stockId) return;
    let cancelled = false;
    setStages([]);
    if (hasProfileSettings(edit)) return;
    session
      .stages(stockId, edit.medium, edit.halationModel, edit.digitalReference)
      .then((next) => {
        if (!cancelled) setStages(next);
      })
      .catch((e) => {
        if (!cancelled) setError(e.message);
      });
    return () => {
      cancelled = true;
    };
  }, [
    panel,
    session,
    stockId,
    edit.medium,
    edit.halationModel,
    edit.digitalReference,
    edit.format,
    edit.profile,
    edit.filters,
  ]);

  async function acceptFiles(incoming) {
    if (exporting) return;
    const generation = ++loadGeneration.current;
    importController.current?.abort();
    const controller = new AbortController();
    importController.current = controller;
    const loaded = [],
      errors = [];
    for (const file of Array.from(incoming || [])) {
      if (controller.signal.aborted) break;
      if (isVideoFile(file) || isEXRFile(file) || isRawFile(file)) {
        try {
          const decoded = await (
            isVideoFile(file)
              ? importVideo
              : isEXRFile(file)
                ? importEXR
                : importRaw
          )(file, {
            signal: controller.signal,
            onProgress: (text) => {
              if (!controller.signal.aborted)
                setImportStatus(`${text}: ${file.name}`);
            },
          });
          loaded.push({ id: crypto.randomUUID(), name: file.name, ...decoded });
        } catch (e) {
          if (e.name !== "AbortError")
            errors.push(`${file.name}: ${e.message}`);
        }
        continue;
      }
      if (
        !file.type.startsWith("image/") &&
        !/\.(png|jpe?g|webp|avif|gif|bmp|tiff?)$/i.test(file.name)
      ) {
        errors.push(`${file.name}: choose a photo, camera RAW file, or video.`);
        continue;
      }
      try {
        const decoded = await importPhoto(file, {
          signal: controller.signal,
          onProgress: (text) => {
            if (!controller.signal.aborted)
              setImportStatus(`${text}: ${file.name}`);
          },
        });
        loaded.push({ id: crypto.randomUUID(), name: file.name, ...decoded });
      } catch (e) {
        if (e.name !== "AbortError")
          errors.push(
            `${file.name}: ${e.message || "Could not decode image."}`,
          );
      }
    }
    if (generation !== loadGeneration.current) {
      loaded.forEach((file) => {
        file.image.video?.dispose();
        URL.revokeObjectURL(file.url);
      });
      return;
    }
    setImportStatus(null);
    importController.current = null;
    if (loaded.length) {
      loaded.forEach((file) => {
        urls.current.add(file.url);
        if (file.image.video) clips.current.add(file.image.video);
      });
      if (activeId) histories.current.set(activeId, history);
      setFiles((current) => [...current, ...loaded]);
      setActiveId(loaded[0].id);
      setVideoTime(loaded[0].image.video?.start || 0);
      dispatch({ type: "load", edit: defaultEdit(edit.stock) });
      replaceResult(null);
      setStage(null);
      setDifference(false);
    }
    setError(errors.length ? errors.join(" ") : null);
  }
  async function openSample() {
    const generation = ++loadGeneration.current;
    try {
      const response = await fetch(assetUrl("demo-scene.exr"));
      if (!response.ok)
        throw new Error("The linear EXR sample could not be loaded.");
      const bytes = await response.arrayBuffer();
      if (generation !== loadGeneration.current) return;
      await acceptFiles([
        new File([bytes], "Scene response.exr", {
          type: "image/x-exr",
        }),
      ]);
    } catch (e) {
      if (generation === loadGeneration.current) setError(e.message);
    }
  }
  useEffect(() => {
    openSample();
  }, []);
  function selectFile(file) {
    if (file.id === activeId || exporting) return;
    histories.current.set(activeId, history);
    setActiveId(file.id);
    setVideoTime(file.image.video?.start || 0);
    dispatch({
      type: "restore",
      history: histories.current.get(file.id) || {
        ...initialHistory,
        present: defaultEdit(edit.stock),
      },
    });
    replaceResult(null);
    setStage(null);
    setDifference(false);
  }
  function removeFile(file) {
    if (exporting) return;
    const remaining = files.filter((item) => item.id !== file.id);
    if (file.id === activeId) {
      const next = remaining[Math.max(0, files.indexOf(file) - 1)];
      setActiveId(next?.id || null);
      setVideoTime(next?.image.video?.start || 0);
      dispatch({
        type: "restore",
        history: histories.current.get(next?.id) || {
          ...initialHistory,
          present: defaultEdit(edit.stock),
        },
      });
      replaceResult(null);
    }
    file.image.video?.dispose();
    clips.current.delete(file.image.video);
    histories.current.delete(file.id);
    setFiles(remaining);
    URL.revokeObjectURL(file.url);
    urls.current.delete(file.url);
  }
  function selectStock(id) {
    if (exporting) return;
    const medium = stocks
      .find((s) => s.id === id)
      ?.media.some((m) => m.id === edit.medium)
      ? edit.medium
      : null;
    const halationModel =
      stocks.find((s) => s.id === id)?.layeredTransport === false
        ? "legacy"
        : edit.halationModel || "legacy";
    patch({
      stock: id,
      medium: halationModel === "layered" ? null : medium,
      halationModel,
    });
    setStage(null);
    setDifference(false);
  }
  function saveEdit() {
    download(
      new Blob([JSON.stringify({ version: 1, edit }, null, 2)], {
        type: "application/json",
      }),
      `${cleanName(active?.name || "photo")}.fotufilm-web.json`,
    );
    setDialog(null);
  }
  async function restoreEdit(file) {
    if (!file) return;
    try {
      const restored = parseEdit(
        await file.text(),
        stocks.map((s) => s.id),
      );
      dispatch({ type: "edit", patch: restored, restoring: true });
      setStage(null);
      setDifference(false);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }
  async function exportClip() {
    if (!active?.image.video || !session || exporting) return;
    const controller = new AbortController();
    videoExportController.current = controller;
    setExporting(true);
    setError(null);
    setStatus("Choose an export destination");
    try {
      const filename = `${cleanName(active.name)}-${edit.stock || "normal"}.${videoFormat}`;
      const destination = await createVideoDestination(filename);
      const saved = await exportVideo({
        image: active.image,
        edit,
        stock: stockId,
        session,
        destination,
        format: videoFormat,
        quality: videoQuality,
        maxEdge: exportSize === "full" ? Infinity : Number(exportSize),
        signal: controller.signal,
        onProgress: ({ progress, frames, finalizing }) =>
          setStatus(
            finalizing
              ? "Finalizing video file"
              : `Exporting video · ${Math.floor(progress * 100)}% · ${frames} frames`,
          ),
      });
      if (!alive.current) {
        await saved.dispose();
        return;
      }
      await videoDownloadRef.current?.dispose();
      videoDownloadRef.current = saved;
      setVideoDownload(saved);
      setDialog(null);
    } catch (error) {
      if (
        error.name !== "AbortError" &&
        error.name !== "ConversionCanceledError" &&
        alive.current
      )
        setError(error.message);
    } finally {
      videoExportController.current = null;
      if (alive.current) {
        setExporting(false);
        setStatus(null);
      }
    }
  }
  async function exportImage() {
    if (!active || !session || !stockId || exporting) return;
    setExporting(true);
    setError(null);
    try {
      const next = await session.render({
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: exportSize === "full" ? Infinity : Number(exportSize),
        comparison: false,
        purpose: "export",
        bitDepth: exportType === "image/tiff" ? 16 : 8,
        onProgress: setStatus,
      });
      if (!next) throw new Error("Export was cancelled.");
      setStatus(`Encoding ${exportType.split("/")[1].toUpperCase()} export`);
      const blob =
        exportType === "image/tiff"
          ? await exportTiff(next)
          : exportType === "image/png"
            ? next.blob
            : await canvasBlob(next.canvas, exportType, quality / 100);
      const extension =
        exportType === "image/jpeg" ? "jpg" : exportType.split("/")[1];
      download(
        blob,
        `${cleanName(active.name)}-${edit.stock || "normal"}${edit.medium ? `-${edit.medium}` : ""}.${extension}`,
      );
      setDialog(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setExporting(false);
      setStatus(null);
    }
  }
  useEffect(() => {
    function keydown(event) {
      const command = event.metaKey || event.ctrlKey;
      if (command && event.shiftKey && event.key.toLowerCase() === "a") {
        if (!auto.available) return;
        event.preventDefault();
        if (isTyping(event.target)) event.target.blur();
        auto.toggle();
        return;
      }
      if (isTyping(event.target) || exporting) return;
      if (command && event.key.toLowerCase() === "o") {
        event.preventDefault();
        input.current?.click();
      } else if (command && event.key.toLowerCase() === "z") {
        event.preventDefault();
        dispatch({ type: event.shiftKey ? "redo" : "undo" });
      } else if (command && event.key.toLowerCase() === "s" && active) {
        event.preventDefault();
        setDialog("export");
      } else if (event.code === "Space" && active) {
        event.preventDefault();
        setCompare(true);
      } else if (event.key === "Escape") {
        setCompare(false);
        setZoom(1);
        if (cropMode) setPanel("film");
      } else if (event.key === "Enter" && cropMode) {
        setPanel("film");
        endEdit();
      } else if (!command && event.key.toLowerCase() === "h")
        setHistogram((v) => !v);
      else if (!command && event.key.toLowerCase() === "c") {
        setPanel("crop");
        setInspectorOpen(true);
      } else if (event.key === "0") setZoom(1);
      else if (event.key === "+" || event.key === "=")
        setZoom((z) => Math.min(8, z + 0.25));
      else if (event.key === "-") setZoom((z) => Math.max(1, z - 0.25));
      else if (event.key === "Tab") return;
    }
    const release = (event) => {
      if (event.code === "Space") setCompare(false);
    };
    const blur = () => {
      setCompare(false);
      endEdit();
    };
    window.addEventListener("keydown", keydown);
    window.addEventListener("keyup", release);
    window.addEventListener("blur", blur);
    return () => {
      window.removeEventListener("keydown", keydown);
      window.removeEventListener("keyup", release);
      window.removeEventListener("blur", blur);
    };
  }, [
    active,
    exporting,
    cropMode,
    endEdit,
    auto.available,
    auto.toggle,
    dispatch,
  ]);

  const visibleStocks = stocks.filter((stock) =>
    stock.name.toLowerCase().includes(search.toLowerCase()),
  );
  const rawWidth = active?.image.naturalWidth || 0,
    rawHeight = active?.image.naturalHeight || 0;
  const width = edit.rotation % 2 ? rawHeight : rawWidth,
    height = edit.rotation % 2 ? rawWidth : rawHeight;
  const cropSize = outputSize(edit.crop, width, height);
  const exportScale =
    exportSize === "full"
      ? 1
      : Math.min(1, Number(exportSize) / Math.max(width, height));
  const exportSourceSize = outputSize(
    edit.crop,
    Math.max(1, Math.round(width * exportScale)),
    Math.max(1, Math.round(height * exportScale)),
  );
  const framedSize = usePrintFrame(
    edit,
    exportSourceSize.width,
    exportSourceSize.height,
    !!active && !active.image.video && edit.printFrame !== "none",
  );
  const shownResult = result?.fileId === activeId ? result : null;
  const adjustments = (group) => (
    <Adjustments
      group={group}
      hasFilm={!!edit.stock}
      params={edit.params}
      onChange={setParam}
      onEnd={endEdit}
      disabled={exporting || !active}
    />
  );

  return (
    <div
      className={`editor ${filmOpen ? "" : "film-collapsed"} ${inspectorOpen ? "" : "inspector-collapsed"}`}
    >
      <header className="toolbar" aria-label="Editor toolbar">
        <div className="toolbar-leading">
          <ToolButton
            icon="sidebar"
            label="Toggle film sidebar"
            active={filmOpen}
            onClick={() => {
              setFilmOpen((v) => !v);
              if (window.innerWidth < 834) setInspectorOpen(false);
            }}
          />
          <span className="app-name">Fotufilm</span>
          <span className="experimental-label">Experimental</span>
          <ToolButton
            icon="open"
            label="Open photos or videos (⌘O)"
            onClick={() => input.current?.click()}
            disabled={exporting}
          />
        </div>
        <div className="toolbar-zoom">
          <ToolButton
            icon="minus"
            label="Zoom out"
            onClick={() => setZoom((z) => Math.max(1, z - 0.25))}
            disabled={!active || zoom === 1 || cropMode}
          />
          <span className="zoom-readout">
            {zoom === 1 ? "Fit" : `${zoomReadout}%`}
          </span>
          <ToolButton
            icon="plus"
            label="Zoom in"
            onClick={() => setZoom((z) => Math.min(8, z + 0.25))}
            disabled={!active || zoom === 8 || cropMode}
          />
          <ToolButton
            icon="fit"
            label="Zoom to fit (0)"
            onClick={() => setZoom(1)}
            disabled={!active || zoom === 1}
          />
          <ToolButton
            icon="selective"
            label="Selective"
            active={panel === "selective" && inspectorOpen}
            onClick={() => setInspector("selective")}
            disabled={!active || exporting || !!active?.image.video}
          />
          <ToolButton
            icon="crop"
            label="Crop"
            active={panel === "crop" && inspectorOpen}
            onClick={() => setInspector("crop")}
            disabled={!active || exporting}
          />
          <span
            className="pixel-readout"
            title={
              active?.image.raw
                ? active.image.raw.profile
                  ? `Camera spectral profile: ${active.image.raw.profile.name} · estimated ${Math.round(active.image.raw.profile.kelvin)} K`
                  : "RAW decoder color · no matching camera spectral correction"
                : undefined
            }
          >
            {active?.image.video
              ? "Video · "
              : active?.image.hdr
                ? "HDR · "
                : active?.image.deep
                  ? `${active.image.deep.format} · ${active.image.deep.bitDepth}-bit · `
                  : active?.image.linear
                    ? "EXR · linear · "
                    : active?.image.raw
                      ? "RAW · "
                      : ""}
            {active
              ? `${((rawWidth * rawHeight) / 1000000).toFixed(1)} MP`
              : ""}
          </span>
        </div>
        <div className="toolbar-trailing">
          <ToolButton
            icon="histogram"
            label="Histogram (H)"
            active={histogram}
            onClick={() => setHistogram((v) => !v)}
            disabled={!active}
          />
          <span className="toolbar-divider" />
          <ToolButton
            icon="undo"
            label="Undo (⌘Z)"
            onClick={() => dispatch({ type: "undo" })}
            disabled={!history.past.length || exporting}
          />
          <ToolButton
            icon="redo"
            label="Redo (⇧⌘Z)"
            onClick={() => dispatch({ type: "redo" })}
            disabled={!history.future.length || exporting}
          />
          <ToolButton
            icon="reset"
            label="Reset all edits"
            onClick={() => {
              dispatch({
                type: "edit",
                patch: defaultEdit(edit.stock),
                restoring: true,
              });
              setStage(null);
              setDifference(false);
            }}
            disabled={!active || exporting}
          />
          <ToolButton
            icon="export"
            label="Export (⌘S)"
            onClick={() => setDialog("export")}
            disabled={!active || !stocks.length || exporting}
          />
          <ToolButton
            icon="more"
            label="More options"
            onClick={() => setDialog("more")}
          />
          <ToolButton
            icon="inspector"
            label="Toggle adjustments"
            active={inspectorOpen}
            onClick={() => {
              setInspectorOpen((v) => !v);
              if (window.innerWidth < 834) setFilmOpen(false);
            }}
          />
        </div>
      </header>
      <aside
        className="film-sidebar"
        aria-label="Film library"
        inert={exporting}
      >
        <div className="sidebar-heading">
          <span>Film</span>
          <small>{stocks.length}</small>
        </div>
        <div className="search-field">
          <TextInput
            label="Search films"
            isLabelHidden
            role="searchbox"
            size="sm"
            placeholder="Search films"
            value={search}
            onChange={setSearch}
            startIcon={<Icon name="search" />}
            width="100%"
          />
        </div>
        <div className="stock-list">
          <button
            className={`stock-row normal-row ${edit.stock === null ? "selected" : ""}`}
            aria-pressed={edit.stock === null}
            onClick={() => selectStock(null)}
          >
            <span className="stock-thumb">
              {active ? <img src={active.url} alt="" /> : <Icon name="film" />}
            </span>
            <span className="stock-copy">
              <span>Normal</span>
              <small>No film</small>
            </span>
            {edit.stock === null && <Icon name="check" />}
          </button>
          {visibleStocks.map((stock) => (
            <StockRow
              key={stock.id}
              stock={stock}
              active={edit.stock === stock.id}
              image={active?.image.video ? null : active?.image}
              session={session}
              onSelect={() => selectStock(stock.id)}
            />
          ))}
          {!visibleStocks.length && !!stocks.length && (
            <p className="empty-search">No matching films.</p>
          )}
        </div>
      </aside>
      <main
        className={`viewer ${dragOver ? "drag-over" : ""}`}
        aria-label="Photo and video editor"
        onDragOver={(e) => {
          e.preventDefault();
          setDragOver(true);
        }}
        onDragLeave={(e) => {
          if (!e.currentTarget.contains(e.relatedTarget)) setDragOver(false);
        }}
        onDrop={(e) => {
          e.preventDefault();
          setDragOver(false);
          acceptFiles(e.dataTransfer.files);
        }}
      >
        {active ? (
          <>
            <ImageCanvas
              sampling={sampling}
              onSample={(point) => {
                if (!shownResult?.sceneSource) return;
                point = frameSamplePoint(point, shownResult.framePlan);
                if (!point) return;
                const selective = edit.selective || newSelection(edit);
                patch({
                  selective: {
                    ...selective,
                    point,
                    sample: sampleScene(shownResult.sceneSource, point),
                  },
                });
                setSampling(false);
              }}
              onDetailError={setError}
              onDetailBackend={setDetailBackend}
              detailSession={session}
              detailRequest={detailRequest}
              detailEnabled={
                !interacting && !exporting && shownResult?.key === previewKey
              }
              result={shownResult}
              original={active.image}
              sourceKey={active.id}
              onInteraction={setViewerMoving}
              zoom={zoom}
              outputWidth={
                cropMode
                  ? width
                  : cropSize.width *
                    (shownResult?.framePlan
                      ? shownResult.width /
                        shownResult.framePlan.placement.image.width
                      : 1)
              }
              onZoomReadout={setZoomReadout}
              setZoom={setZoom}
              compare={compare}
              setCompare={setCompare}
              cropMode={cropMode}
              crop={edit.crop}
              cropShape={edit.cropShape}
              cropRatio={edit.ratio}
              cropIdentity={JSON.stringify([
                activeId,
                edit.rotation,
                edit.flip,
                edit.straighten,
                edit.perspectiveV,
                edit.perspectiveH,
              ])}
              onCrop={(crop) => patch({ crop }, "crop")}
              onEnd={endEdit}
              showHistogram={histogram ? () => setHistogram(false) : null}
            />
            {active.image.video && (
              <VideoControls
                key={active.id}
                clip={active.image.video}
                time={videoTime}
                onTime={setVideoTime}
                settings={edit.video}
                onChange={(video) => patch({ video })}
                disabled={exporting || cropMode}
              />
            )}
          </>
        ) : (
          <div className="empty-canvas">
            <Icon name="open" />
            <h1>Open a photo or video</h1>
            <p>Drop photos or videos here, or choose files.</p>
            <Button
              label="Open photos or videos"
              variant="primary"
              size="sm"
              className="primary"
              onClick={() => input.current?.click()}
            />
            <Button
              label="Open linear EXR sample"
              variant="ghost"
              size="sm"
              className="text-button"
              onClick={openSample}
            />
            <small>
              EXR, RAW, photos, MP4, MOV, WebM · processed on this device
            </small>
          </div>
        )}
        {importStatus && (
          <div className="import-status" role="status">
            <span>{importStatus}</span>
            <Button
              label="Cancel"
              variant="ghost"
              size="sm"
              onClick={() => {
                importController.current?.abort();
                setImportStatus(null);
              }}
            />
          </div>
        )}
        {dragOver && <div className="drop-label">Drop images to open</div>}
        {visibleError && (
          <div className="error-banner" role="alert">
            <span>{visibleError}</span>
            <Button
              label="Retry"
              variant="ghost"
              size="sm"
              onClick={() => {
                setError(null);
                setRetry((v) => v + 1);
              }}
            />
            <button
              aria-label="Dismiss error"
              onClick={() => {
                setError(null);
                setLibraryError(null);
              }}
            >
              <Icon name="close" size={14} />
            </button>
          </div>
        )}
        <div className="viewer-status">
          <span className="document-name">
            {active?.name || "No photo open"}
          </span>
          <span role="status">
            {auto.status ||
              status ||
              (active && shownResult?.key !== previewKey
                ? error
                  ? "Preview unavailable"
                  : interacting
                    ? "Waiting for adjustments to settle before full-detail preview"
                    : "Waiting for the next display frame"
                : null) ||
              (shownResult
                ? `${shownResult.width} × ${shownResult.height} · ${shownResult.elapsed.toFixed(0)} ms`
                : "")}
          </span>
          {active && (
            <Button
              label="Compare"
              variant="ghost"
              size="sm"
              className={`compare-button ${compare ? "active" : ""}`}
              onPointerDown={(e) => {
                e.currentTarget.setPointerCapture(e.pointerId);
                setCompare(true);
              }}
              onPointerUp={() => setCompare(false)}
              onPointerCancel={() => setCompare(false)}
              onKeyDown={(e) => {
                if (e.key === " " || e.key === "Enter") {
                  e.preventDefault();
                  setCompare(true);
                }
              }}
              onKeyUp={() => setCompare(false)}
              onBlur={() => setCompare(false)}
              aria-label="Hold to compare with original"
              icon={<Icon name="compare" />}
            />
          )}
          <span className="backend-label">
            {(detailBackend || shownResult?.backend) === "webgpu"
              ? "WebGPU"
              : shownResult
                ? "CPU"
                : ""}
          </span>
        </div>
        {files.length > 1 && (
          <div className="filmstrip" aria-label="Open photos">
            {files.map((file) => (
              <div
                className={`filmstrip-item ${file.id === activeId ? "selected" : ""}`}
                key={file.id}
              >
                <button
                  aria-label={`Select ${file.name}`}
                  onClick={() => selectFile(file)}
                >
                  <img src={file.url} alt={file.name} />
                </button>
                <button
                  className="close-photo"
                  aria-label={`Close ${file.name}`}
                  onClick={() => removeFile(file)}
                >
                  <Icon name="close" size={14} />
                </button>
              </div>
            ))}
          </div>
        )}
      </main>
      {!inspectorOpen && (
        <nav className="inspector-rail" aria-label="Adjustment panels">
          {inspectorPanels.map((p) => (
            <ToolButton
              key={p.id}
              icon={p.icon}
              label={p.title}
              active={panel === p.id}
              onClick={() => setInspector(p.id)}
            />
          ))}
        </nav>
      )}
      <aside
        className="inspector"
        aria-label="Adjustments"
        hidden={!inspectorOpen}
      >
        <div className="darkroom-heading">
          <h2>
            {panel === "crop"
              ? "Crop"
              : panel === "selective"
                ? "Selective"
                : "Darkroom"}
          </h2>
          <details className="darkroom-help" key={panel}>
            <summary
              aria-label={`Help for ${inspectorPanels.find((p) => p.id === panel)?.title || panel}`}
            >
              <Icon name="help" size={14} />
            </summary>
            <p>
              {
                {
                  film: "Load a stock and choose its format and character.",
                  light:
                    "Adjust the light and filters, then refine the colour grade.",
                  develop:
                    "Develop the film, then shape its grain and colour separation.",
                  print:
                    "Choose a print or scan, set its viewing light, and export.",
                  selective: "Adjust a selected colour, area, or subject.",
                  crop: "Frame and straighten the finished photograph.",
                }[panel]
              }
            </p>
          </details>
          {["crop", "selective"].includes(panel) && <span>Canvas tool</span>}
        </div>
        <TabList
          role="tablist"
          className="inspector-tabs"
          aria-label="Adjustment panels"
          value={panel}
          onChange={setInspector}
          layout="fill"
          overflow="scroll"
          size="sm"
          hasDivider={false}
        >
          {inspectorPanels.map(({ id, title }) => (
            <Tab
              key={id}
              value={id}
              label={title}
              panelId="inspector-content"
            />
          ))}
        </TabList>
        <InspectorPanel
          panel={panel}
          disabled={exporting || !active}
          label={
            inspectorPanels.find((p) => p.id === panel)?.title ||
            (panel === "crop"
              ? "Crop"
              : panel === "selective"
                ? "Selective"
                : "Pipeline")
          }
        >
          {panel === "film" && (
            <>
              <Section title={edit.stock ? "Loaded Film" : "Normal"}>
                {edit.stock ? (
                  <>
                    <div className="info-row">
                      <span>Stock</span>
                      <span>{selectedStock?.name}</span>
                    </div>
                    <p className="medium-detail">
                      Choose a stock from the film library on the left.
                    </p>
                  </>
                ) : (
                  <p className="medium-detail">
                    Film simulation is off. Choose a film from the library. With
                    Normal selected, use Expose to adjust the source and Print
                    to finish the image.
                  </p>
                )}
                <p className="medium-detail">
                  Click and hold the photo to compare with the original.
                </p>
              </Section>
              {edit.stock && (
                <>
                  <Section title="Film Format">
                    <Selector
                      label="Format"
                      size="sm"
                      width="100%"
                      isDisabled={
                        exporting || !active || edit.halationModel === "layered"
                      }
                      value={edit.format || "film"}
                      options={[
                        { value: "film", label: "Match Film" },
                        ...FILM_FORMATS.map((f) => ({
                          value: f.id,
                          label: f.name,
                        })),
                      ]}
                      onChange={(format) => {
                        endEdit();
                        patch({ format: format === "film" ? null : format });
                        setStage(null);
                        setDifference(false);
                      }}
                    />
                  </Section>
                  <Section title="Film Condition">
                    {profileControls(["expired"])}
                  </Section>
                </>
              )}
              {edit.stock && (
                <Section title="Halation">
                  <Selector
                    label="Halation Model"
                    size="sm"
                    width="100%"
                    value={edit.halationModel || "legacy"}
                    options={[
                      { value: "legacy", label: "Legacy" },
                      ...(selectedStock?.layeredTransport === false ||
                      sceneKelvin ||
                      hasProfileSettings(edit)
                        ? []
                        : [{ value: "layered", label: "Layered Transport" }]),
                    ]}
                    onChange={(halationModel) => {
                      endEdit();
                      patch({ halationModel, medium: null });
                      setStage(null);
                      setDifference(false);
                    }}
                  />
                  {profileControls([
                    "halation",
                    "halationReturn",
                    "halationColour",
                    "halationSpectrum",
                    "estimatedHalation",
                  ])}
                  {hasProfileSettings(edit) && (
                    <p className="medium-detail">
                      Custom film settings use Legacy halation.
                    </p>
                  )}
                  {sceneKelvin && (
                    <p className="medium-detail">
                      Custom source illumination uses Legacy halation.
                    </p>
                  )}
                  {edit.halationModel === "layered" && (
                    <p className="medium-detail">
                      Uses the film’s default format, condition, grain model and
                      output medium. Choose Legacy to adjust these settings.
                      Pipeline inspection is available with Legacy.
                    </p>
                  )}
                </Section>
              )}
            </>
          )}
          {panel === "develop" &&
            (edit.stock ? (
              <>
                <Section title="Development">
                  {profileControls(["push", "bleach"])}
                  <p className="medium-detail">
                    Push and pull are available only when the film has measured
                    settings. Bleach bypass retains silver in the negative.
                  </p>
                </Section>
                <Section title="Grain">
                  {adjustments("Character")}
                  {profileControls(["grainMottle", "grainModel"])}
                  <Button
                    label="New Grain Pattern"
                    variant="secondary"
                    size="sm"
                    className="secondary full-width"
                    onClick={() =>
                      patch({
                        seed: crypto.getRandomValues(new Uint32Array(1))[0],
                      })
                    }
                  />
                </Section>
                {selectedStock?.available.some((field) =>
                  [
                    "couplers",
                    "couplerReach",
                    "couplerSelf",
                    "chromaticFringeAmount",
                  ].includes(field),
                ) && (
                  <Section title="Colour Separation">
                    {profileControls([
                      "couplers",
                      "couplerReach",
                      "couplerSelf",
                      "chromaticFringeAmount",
                      "chromaticFringeRadius",
                    ])}
                  </Section>
                )}
              </>
            ) : (
              <Section title="Normal">
                <p>
                  Choose a film from the library to use development and grain.
                </p>
              </Section>
            ))}
          {panel === "print" && (
            <>
              <Section title="Output">
                <Selector
                  label="Output medium"
                  size="sm"
                  width="100%"
                  isDisabled={
                    exporting ||
                    !active ||
                    !edit.stock ||
                    edit.halationModel === "layered"
                  }
                  value={
                    edit.medium || selectedStock?.defaultMedium || "screen"
                  }
                  options={(
                    selectedStock?.media || [
                      { id: "screen", name: "Digital Reference" },
                    ]
                  ).map((medium) => ({
                    value: medium.id,
                    label: medium.name,
                  }))}
                  onChange={(medium) => {
                    endEdit();
                    patch({ medium });
                    setStage(null);
                    setDifference(false);
                  }}
                />
                {(edit.medium || selectedStock?.defaultMedium) === "screen" &&
                  selectedStock?.media.find((m) => m.id === "screen")
                    ?.screenConversions && (
                    <Selector
                      label={SCREEN_CONVERSION.title}
                      size="sm"
                      width="100%"
                      isDisabled={
                        exporting || !active || edit.halationModel === "layered"
                      }
                      value={edit.digitalReference || SCREEN_CONVERSION.default}
                      options={SCREEN_CONVERSION.choices.map((c) => ({
                        value: c.id,
                        label: c.name,
                      }))}
                      onChange={(digitalReference) => {
                        endEdit();
                        patch({ digitalReference });
                        setStage(null);
                        setDifference(false);
                      }}
                    />
                  )}
                {profileControls([
                  "printLight",
                  "printCorrection",
                  "negativeViewing",
                  "screenGrade",
                  "screenExposure",
                ])}
                {selectedStock && (
                  <p className="medium-detail">
                    {(edit.medium || selectedStock.defaultMedium) === "screen"
                      ? "Direct display rendering without paper or scanning."
                      : selectedStock.media.find(
                          (m) =>
                            m.id ===
                            (edit.medium || selectedStock.defaultMedium),
                        )?.detail}
                  </p>
                )}
                <div className="info-row">
                  <span>Color space</span>
                  <span>{colorSpaceLabel(preferredCanvasColorSpace())}</span>
                </div>
              </Section>

              {profileMedium(edit, selectedStock)?.enlarger && (
                <Section title="Lamp">
                  {profileControls([
                    "enlarger",
                    "printerEnabled",
                    "printerLamp",
                    "printerExposure",
                    "printerMagenta",
                    "printerYellow",
                    "printerPreflash",
                  ])}
                  <p className="medium-detail">
                    {edit.profile?.printerEnabled
                      ? "A simulated tungsten lamp and colour filters expose the paper through the film. More exposure darkens negative paper and lightens positive paper."
                      : "Enable Simulated Printer to adjust lamp temperature, paper exposure and filtration."}
                  </p>
                </Section>
              )}
              <PrintFrameControls
                edit={edit}
                image={active?.image}
                disabled={exporting || !active}
                onChange={(printFrame) => {
                  endEdit();
                  patch({
                    printFrame,
                    ...(["film", "slideMount"].includes(printFrame)
                      ? { halationModel: "legacy" }
                      : {}),
                  });
                  setStage(null);
                  setDifference(false);
                }}
              />
              <Section title="Export">
                <Button
                  label={
                    active?.image.video ? "Export Video…" : "Export Photo…"
                  }
                  variant="secondary"
                  size="sm"
                  onClick={() => setDialog("export")}
                />
              </Section>
            </>
          )}
          {panel === "light" && (
            <>
              <Section title="Light">
                {adjustments("Light")}
                <Switch
                  label="Regional"
                  value={edit.localTone}
                  onChange={(value) => patch({ localTone: value })}
                  isDisabled={exporting || !active}
                  labelPosition="start"
                  labelSpacing="spread"
                  size="sm"
                />
              </Section>
              <Section title="Source Illuminant">
                <Selector
                  label={editorControl("sceneLight").title}
                  size="sm"
                  width="100%"
                  value={edit.sceneLight}
                  options={editorControl("sceneLight").choices.map((c) => ({
                    value: c.id,
                    label: c.label,
                  }))}
                  onChange={(sceneLight) => {
                    endEdit();
                    patch({
                      sceneLight,
                      ...(sceneLight !== "unspecified"
                        ? { halationModel: "legacy" }
                        : {}),
                    });
                  }}
                />
                {edit.sceneLight === "custom" &&
                  adjustments("Source Illuminant")}
                <p className="medium-detail">
                  {editorControl("sceneLight").detail}
                </p>
              </Section>
              <Section title="White Balance">
                {adjustments("White Balance")}
              </Section>
              <Section title="Color">{adjustments("Color")}</Section>
              <Section title="Grade">
                <Switch
                  label="Encoded Grade"
                  value={edit.gradeSpace}
                  onChange={(value) => patch({ gradeSpace: value })}
                  isDisabled={exporting || !active}
                  labelPosition="start"
                  labelSpacing="spread"
                  size="sm"
                />
                {["Shadows", "Midtones", "Highlights"].map((band) => (
                  <div
                    className="grade-band"
                    key={band}
                    role="group"
                    aria-label={band}
                  >
                    <h3>{band}</h3>
                    {adjustments(band)}
                  </div>
                ))}
              </Section>
            </>
          )}
          {panel === "light" &&
            selectedStock?.available.includes("shutter") && (
              <Section title="Long Exposure">
                {profileControls(["shutter"])}
              </Section>
            )}
          {panel === "light" && (
            <LensFilters
              edit={edit}
              stock={selectedStock}
              disabled={
                exporting || !active || edit.halationModel === "layered"
              }
              onChange={(value) => {
                endEdit();
                patch(value);
                setStage(null);
                setDifference(false);
              }}
            />
          )}
          {panel === "light" && (
            <LensControls
              image={active?.image}
              lens={edit.lens}
              disabled={exporting || !active}
              onEnd={endEdit}
              onChange={(lens, group) => {
                patch({ lens }, group);
                setStage(null);
                setDifference(false);
              }}
            />
          )}
          {panel === "light" && (
            <SourceInterpretationControls
              image={active?.image}
              value={edit.sourceInterpretation}
              disabled={exporting}
              onChange={(sourceInterpretation) => {
                endEdit();
                patch({ sourceInterpretation });
                setStage(null);
                setDifference(false);
              }}
            />
          )}
          {panel === "selective" && (
            <SelectiveControls
              disabled={exporting || !active}
              edit={edit}
              patch={patch}
              endEdit={endEdit}
              sampling={sampling}
              setSampling={setSampling}
              showMask={showMask}
              setShowMask={setShowMask}
              canSample={!!shownResult?.sceneSource}
            />
          )}
          {panel === "crop" && (
            <CropControls
              edit={edit}
              width={width}
              height={height}
              size={cropSize}
              disabled={exporting || !active}
              patch={patch}
              onEnd={endEdit}
              onDone={() => {
                endEdit();
                setPanel("film");
              }}
            />
          )}
          {panel === "pipeline" && (
            <>
              <div className="inspector-title">
                <h2>Pipeline</h2>
              </div>
              {hasProfileSettings(edit) && (
                <p className="inspector-hint">
                  Individual pipeline stages are available with the film’s
                  default film, print and filter settings.
                </p>
              )}
              <div className="pipeline-list">
                <Button
                  label="Finished print"
                  variant="ghost"
                  size="sm"
                  className={stage === null ? "selected" : ""}
                  onClick={() => {
                    setStage(null);
                    setDifference(false);
                  }}
                />
                {stages.map((item, i) => (
                  <button
                    key={item.id}
                    className={stage === i ? "selected" : ""}
                    onClick={() => setStage(i)}
                    disabled={!edit.stock}
                  >
                    <span>{String(i + 1).padStart(2, "0")}</span>
                    {stageNames[i] || item.label}
                  </button>
                ))}
              </div>
              <label className="toggle-row">
                <span>Show stage difference</span>
                <input
                  type="checkbox"
                  checked={difference}
                  onChange={(e) => setDifference(e.target.checked)}
                  disabled={stage === null || stage === 0}
                />
              </label>
              {result?.delta && (
                <p className="inspector-hint">
                  {result.delta.gain.toFixed(1)}× gain · {result.delta.peak}
                  /255 peak
                </p>
              )}
            </>
          )}
        </InspectorPanel>
      </aside>
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
      {dialog === "negative" && (
        <NegativeImportDialog
          onClose={() => setDialog(null)}
          onImport={(file) => {
            urls.current.add(file.url);
            if (activeId) histories.current.set(activeId, history);
            setFiles((current) => [...current, file]);
            setActiveId(file.id);
            dispatch({ type: "load", edit: defaultEdit(null) });
            replaceResult(null);
            setStage(null);
            setDifference(false);
            setVideoTime(0);
            setDialog(null);
            setInspector("crop");
          }}
        />
      )}
      {dialog === "export" && (
        <Modal
          title={active?.image.video ? VIDEO_LABELS.export : "Export image"}
          onClose={() => {
            if (!exporting) setDialog(null);
          }}
        >
          <fieldset disabled={exporting}>
            <label className="select-row">
              Format
              <select
                aria-label="Format"
                value={active?.image.video ? videoFormat : exportType}
                onChange={(e) =>
                  active?.image.video
                    ? setVideoFormat(e.target.value)
                    : setExportType(e.target.value)
                }
              >
                {active?.image.video ? (
                  <>
                    <option value="mp4">{VIDEO_LABELS.mp4}</option>
                    <option value="webm">{VIDEO_LABELS.webm}</option>
                  </>
                ) : (
                  <>
                    <option value="image/png">PNG</option>
                    <option value="image/tiff">TIFF · 16-bit</option>
                    <option value="image/jpeg">JPEG</option>
                    <option value="image/webp">WebP</option>
                  </>
                )}
              </select>
            </label>
            <label className="select-row">
              Size
              <select
                aria-label="Size"
                value={exportSize}
                onChange={(e) => setExportSize(e.target.value)}
              >
                <option value="full">Full resolution</option>
                <option value="3840">3840 px long edge</option>
                <option value="2048">2048 px long edge</option>
                <option value="1600">1600 px long edge</option>
              </select>
            </label>
            {!active?.image.video &&
              ["image/jpeg", "image/webp"].includes(exportType) && (
                <Adjustment
                  slider={{
                    key: "quality",
                    label: "Quality",
                    min: 1,
                    max: 100,
                    step: 1,
                    def: 95,
                    unit: "%",
                  }}
                  disabled={exporting}
                  value={quality}
                  onChange={setQuality}
                />
              )}
            {active?.image.video && (
              <label className="select-row">
                Quality
                <select
                  aria-label={VIDEO_LABELS.quality}
                  value={videoQuality}
                  onChange={(e) => setVideoQuality(e.target.value)}
                >
                  <option value="medium">{VIDEO_LABELS.medium}</option>
                  <option value="high">{VIDEO_LABELS.high}</option>
                  <option value="very-high">{VIDEO_LABELS.veryHigh}</option>
                </select>
              </label>
            )}
            <p className="export-detail">
              {active?.image.video
                ? videoDimensions(
                    active.image,
                    edit,
                    exportSize === "full" ? Infinity : Number(exportSize),
                  ).width
                : (framedSize.plan?.placement.size.width ??
                  Math.max(1, Math.round(cropSize.width * exportScale)))}{" "}
              ×{" "}
              {active?.image.video
                ? videoDimensions(
                    active.image,
                    edit,
                    exportSize === "full" ? Infinity : Number(exportSize),
                  ).height
                : (framedSize.plan?.placement.size.height ??
                  Math.max(1, Math.round(cropSize.height * exportScale)))}{" "}
              pixels ·{" "}
              {colorSpaceLabel(
                active?.image.video
                  ? "srgb"
                  : exportType === "image/tiff"
                    ? "display-p3"
                    : preferredCanvasColorSpace(),
              )}{" "}
              ·{" "}
              {exportType === "image/tiff" && !active?.image.video
                ? "16-bit"
                : "8-bit"}
            </p>
            <p className="export-detail">
              {active?.image.video
                ? "Exports every frame in the trim range with the current film, crop, and adjustments. Writes directly to disk; no upload. Odd dimensions are padded by one pixel."
                : "Exports the finished image with the current crop and adjustments."}
            </p>
          </fieldset>
          {!active?.image.video && framedSize.error && (
            <p role="alert">{framedSize.error}</p>
          )}
          {exporting && <p role="status">{status || "Preparing export"}</p>}
          <div className="dialog-actions">
            <Button
              label="Cancel"
              variant="secondary"
              size="sm"
              className="secondary"
              onClick={() =>
                exporting
                  ? videoExportController.current?.abort()
                  : setDialog(null)
              }
              isDisabled={exporting && !active?.image.video}
            />
            <Button
              label={exporting ? "Exporting…" : "Export"}
              variant="primary"
              size="sm"
              onClick={active?.image.video ? exportClip : exportImage}
              isDisabled={exporting}
            />
          </div>
        </Modal>
      )}
      {videoDownload && (
        <div className="video-download" role="status">
          {videoDownload.url ? (
            <a href={videoDownload.url} download={videoDownload.filename}>
              Download {videoDownload.filename}
            </a>
          ) : (
            <span>Saved {videoDownload.filename}</span>
          )}
          <button
            onClick={async () => {
              await videoDownload.dispose();
              videoDownloadRef.current = null;
              setVideoDownload(null);
            }}
          >
            {VIDEO_LABELS.dismiss}
          </button>
        </div>
      )}
      {dialog === "more" && (
        <Modal title="Options" onClose={() => setDialog(null)}>
          <div className="menu-options">
            <Button
              label="Import Scanned Negative…"
              variant="secondary"
              size="sm"
              isDisabled={exporting}
              onClick={() => setDialog("negative")}
            />
            <AutoAdjustmentAction
              auto={auto}
              onClick={() => {
                auto.toggle();
                setDialog(null);
              }}
            />
            <Button
              label="Save edits…"
              variant="secondary"
              size="sm"
              onClick={saveEdit}
              isDisabled={!active}
            />
            <Button
              label="Load edits…"
              variant="ghost"
              size="sm"
              onClick={() => {
                setDialog(null);
                editInput.current?.click();
              }}
              isDisabled={!active}
            />
            <Button
              label="Selective"
              variant="ghost"
              size="sm"
              isDisabled={!active || !!active.image.video}
              onClick={() => {
                setInspector("selective");
                setDialog(null);
              }}
            />
            <Button
              label="Crop"
              variant="ghost"
              size="sm"
              isDisabled={!active || !!active.image.video}
              onClick={() => {
                setInspector("crop");
                setDialog(null);
              }}
            />
            <Button
              label="Inspect pipeline"
              variant="ghost"
              size="sm"
              onClick={() => {
                setInspector("pipeline");
                setDialog(null);
              }}
            />
            <Button
              label="Keyboard shortcuts"
              variant="ghost"
              size="sm"
              onClick={() => setDialog("shortcuts")}
            />
            <Button
              label="Browser support"
              variant="ghost"
              size="sm"
              onClick={() => setDialog("support")}
            />
          </div>
        </Modal>
      )}
      {dialog === "shortcuts" && (
        <Modal title="Keyboard shortcuts" onClose={() => setDialog(null)}>
          <dl className="shortcuts">
            {[
              ["Open images", "⌘ / Ctrl O"],
              ["Export", "⌘ / Ctrl S"],
              ["Undo", "⌘ / Ctrl Z"],
              ["Redo", "⇧ ⌘ / Ctrl Z"],
              [editorControl("autoAdjustment").title, "⇧ ⌘ / Ctrl A"],
              ["Compare", "Hold Space"],
              ["Histogram", "H"],
              ["Crop", "C"],
              ["Apply crop", "Return"],
              ["Zoom", "+ / −"],
              ["Fit", "0"],
              ["Reset adjustment", "Double-click slider"],
            ].map(([action, keys]) => (
              <div key={action}>
                <dt>{action}</dt>
                <dd>{keys}</dd>
              </div>
            ))}
          </dl>
        </Modal>
      )}
      {dialog === "support" && (
        <Modal title="Browser support" onClose={() => setDialog(null)}>
          <div className="support-copy">
            <p>
              Photos and videos are processed on this device. WebGPU is used
              when available, with WebAssembly CPU fallback.
            </p>
            <p>
              A smaller overview keeps movement smooth. Once movement settles,
              the visible image is developed at the display’s pixel resolution.
              Export develops the entire image at the selected size.
            </p>
            <p>
              The browser supports film selection and format, ageing, halation,
              grain models, measured push/pull, bleach bypass, colour
              separation, print viewing, a simulated printer, an ordered
              lens-filter stack, automatic and manual lens correction, Auto
              Adjust, photo frames, light and color adjustments, three-way
              grading, color and light selections, crop, rotation and flip.
              Camera RAW files use as-shot white balance. RAW, linear EXR and
              supported HDR JPEG gain maps preserve decoded highlight detail
              before film exposure.
            </p>
            <p>
              Scanned-negative conversion, automatic subject selections, custom
              packs, and HDR export are available in the Mac app. Still previews
              and exports use Display P3 where supported; TIFF preserves 16-bit
              Display P3 precision. Other browsers use sRGB for canvas output.
            </p>
          </div>
        </Modal>
      )}
    </div>
  );
}
