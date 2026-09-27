import { useAutoAdjustment } from "../useAutoAdjustment.js";
import { useCallback } from "react";
import { defaultEdit } from "../editor-state.js";
export default function useEditingActions({
  compactLayout,
  active,
  session,
  history,
  historyDispatch,
  exporting,
  fixedSettings,
  setError,
  setStage,
  setDifference,
  edit,
  selectedStock,
  setPanel,
  setSampling,
  setShowMask,
  setInspectorOpen,
  setFilmOpen,
  setCompare,
  setZoom,
}) {
  const auto = useAutoAdjustment({
    image: active?.image,
    session,
    history,
    dispatch: historyDispatch,
    disabled: exporting || fixedSettings,
    onError: setError,
    onApplied: () => {
      setStage(null);
      setDifference(false);
    },
  });
  const dispatch = auto.dispatch;
  const patch = useCallback(
    (value, group) =>
      dispatch({
        type: "edit",
        patch: value,
        group,
      }),
    [dispatch],
  );
  const endEdit = useCallback(
    () =>
      dispatch({
        type: "end",
      }),
    [dispatch],
  );
  const setProfile = (key, value) => {
    patch(
      {
        profile: {
          ...edit.profile,
          [key]: value,
        },
      },
      `profile-${key}`,
    );
    setStage(null);
    setDifference(false);
  };
  const setParam = (key, value) =>
    patch(
      {
        params: {
          ...edit.params,
          [key]: value,
        },
      },
      key,
    );
  const setInspector = (value) => {
    endEdit();
    setPanel(value);
    setSampling(false);
    setShowMask(false);
    if (value === "selective") {
      setStage(null);
      setDifference(false);
    }
    const showFilms = compactLayout && value === "film";
    setInspectorOpen(!showFilms);
    if (compactLayout) setFilmOpen(showFilms);
    setCompare(false);
  };
  // Shared by the toolbars, the keyboard and the native menu bar.
  const resetEdits = () => {
    dispatch({
      type: "edit",
      patch: defaultEdit(edit.stock),
      restoring: true,
    });
    setStage(null);
    setDifference(false);
  };
  const toggleInspector = () => {
    setInspectorOpen((v) => !v);
    if (compactLayout) setFilmOpen(false);
  };
  const toggleFilms = () => {
    endEdit();
    setFilmOpen((open) => !open);
  };
  const zoomIn = useCallback(
    () => setZoom((z) => Math.min(8, z + 0.25)),
    [setZoom],
  );
  const zoomOut = useCallback(
    () => setZoom((z) => Math.max(1, z - 0.25)),
    [setZoom],
  );
  return {
    auto,
    dispatch,
    patch,
    endEdit,
    setProfile,
    setParam,
    setInspector,
    resetEdits,
    toggleInspector,
    toggleFilms,
    zoomIn,
    zoomOut,
  };
}
