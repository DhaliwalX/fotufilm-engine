import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { PreviewQueue } from "../preview-queue.js";
import {
  createHistory,
  historyReducer,
  copiedConversion,
  copyConversion,
  adoptConversion,
} from "./recipe.js";

const EMPTY = createHistory(null);

// Which picture the canvas shows: the print, the negative behind it, or the whole negative while
// clear film is being picked; cropped unless the Frame tab is framing it.
export function previewRequest({ tab, picking, showNegative }) {
  if (picking) return { negative: true, cropped: false };
  if (tab === "frame") return { negative: false, cropped: false };
  return { negative: showNegative, cropped: true };
}

// One scan open for conversion, as the apps' NegativeScanSession holds it: the scan's handle in
// the engine, the recipe and its history, and previews in which each new one waits only for the
// one in flight. `scans` is the backend's negativeScans.
export function useNegativeScanSession(scans, open) {
  const [file, setFile] = useState(null);
  const [linearSamples, setLinearSamples] = useState(false);
  const [scan, setScan] = useState(null);
  const [history, dispatch] = useReducer(historyReducer, EMPTY);
  const [tab, setTab] = useState("convert");
  const [picking, setPicking] = useState(false);
  const [showNegative, setShowNegative] = useState(false);
  const [maxEdge, setMaxEdge] = useState(1600);
  const [frame, setFrame] = useState(null);
  const [status, setStatus] = useState("Choose an unadjusted scan or camera RAW negative.");
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [lightFrames, setLightFrames] = useState([]);
  const [canPaste, setCanPaste] = useState(() => copiedConversion() !== null);
  const queue = useRef(null);
  const handle = scan?.handle;
  const recipe = history.recipe;

  // Closing forgets the scan; the next opens from the start.
  useEffect(() => {
    if (open) return;
    setFile(null);
    setLinearSamples(false);
    setTab("convert");
    setPicking(false);
    setShowNegative(false);
    setError(null);
  }, [open]);

  // Decode the scan once per file and encoding; the engine holds it until released.
  useEffect(() => {
    if (!scans || !open || !file) return;
    const controller = new AbortController();
    let opened = null;
    setScan(null);
    setFrame(null);
    setError(null);
    setBusy(true);
    setStatus("Reading negative…");
    scans
      .open(file, { linearSamples, signal: controller.signal })
      .then((result) => {
        opened = result.handle;
        if (controller.signal.aborted) return;
        setScan(result);
        setLightFrames(result.lightFrames ?? []);
        dispatch({ type: "reset", recipe: result.recipe });
        setStatus("");
      })
      .catch((failure) => {
        if (controller.signal.aborted) return;
        setError(failure.message);
        setStatus("");
      })
      .finally(() => {
        if (!controller.signal.aborted) setBusy(false);
      });
    return () => {
      controller.abort();
      if (opened) scans.release(opened).catch(() => {});
      setScan(null);
      dispatch({ type: "reset", recipe: null });
    };
  }, [scans, file, linearSamples, open]);

  useEffect(() => {
    const previews = new PreviewQueue();
    queue.current = previews;
    return () => previews.close();
  }, []);

  // Every change of recipe or view prints again; a slider's run waits only for the print in
  // flight, then takes its newest position.
  const { negative, cropped } = previewRequest({ tab, picking, showNegative });
  useEffect(() => {
    if (!handle || !recipe) return;
    const requested = performance.now();
    const view = { negative, cropped };
    queue.current
      .submit(async () => {
        const result = await scans.render(handle, recipe, { ...view, maxEdge });
        return { ...result, requested, view };
      })
      .then((next) => {
        if (next) {
          setFrame(next);
          setError(null);
        }
      })
      .catch((failure) => {
        setError(failure.message);
      });
  }, [scans, handle, recipe, negative, cropped, maxEdge]);

  const edit = useCallback(
    (change, { stroke = false } = {}) => dispatch({ type: "edit", change, stroke }),
    [],
  );
  const endStroke = useCallback(() => dispatch({ type: "endStroke" }), []);

  async function sampleBorder(area) {
    try {
      const sampled = await scans.sampleBorder(handle, recipe, area);
      edit((current) => ({ ...current, border: sampled.border, borderArea: sampled.borderArea }));
      setPicking(false);
      setStatus("Film base sampled.");
    } catch (failure) {
      setError(failure.message);
    }
  }

  async function findFrame() {
    try {
      const crop = await scans.detectFrame(handle, recipe);
      if (!crop) return setStatus("No frame edge found");
      edit((current) => ({ ...current, crop }));
      setStatus("");
    } catch (failure) {
      setError(failure.message);
    }
  }

  async function addLightFrame(lightFile) {
    try {
      const added = await scans.addLightFrame(lightFile);
      setLightFrames(await scans.lightFrames());
      edit((current) => ({ ...current, lightFrameID: added.id }));
    } catch (failure) {
      setError(failure.message);
    }
  }

  async function removeLightFrame(id) {
    await scans.removeLightFrame(id);
    setLightFrames(await scans.lightFrames());
    if (recipe?.lightFrameID === id) edit((current) => ({ ...current, lightFrameID: null }));
  }

  function copy() {
    copyConversion(recipe);
    setCanPaste(true);
  }

  function paste() {
    const copied = copiedConversion();
    if (copied) edit((current) => adoptConversion(current, copied));
  }

  // The full-resolution positive, handed to `onImport` as a photograph the editor owns.
  async function commit(onImport) {
    if (!handle || busy) return;
    setBusy(true);
    setError(null);
    setStatus("Converting full resolution…");
    try {
      const committed = await scans.commit(handle, recipe);
      onImport(committed, recipe);
    } catch (failure) {
      setError(failure.message);
      setStatus("");
    } finally {
      setBusy(false);
    }
  }

  return {
    file,
    setFile,
    linearSamples,
    setLinearSamples,
    scan,
    recipe,
    canUndo: history.undo.length > 0,
    canRedo: history.redo.length > 0,
    undo: () => dispatch({ type: "undo" }),
    redo: () => dispatch({ type: "redo" }),
    edit,
    endStroke,
    tab,
    setTab: (next) => {
      setPicking(false);
      setTab(next);
    },
    picking,
    setPicking,
    showNegative,
    setShowNegative,
    setMaxEdge,
    frame,
    status,
    error,
    busy,
    lightFrames,
    canPaste,
    sampleBorder,
    findFrame,
    addLightFrame,
    removeLightFrame,
    copy,
    paste,
    commit,
  };
}
