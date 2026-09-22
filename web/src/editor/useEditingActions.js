import { useAutoAdjustment } from "../useAutoAdjustment.js";
import { useCallback } from "react";
export default function useEditingActions({
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
    setInspectorOpen(true);
    if (window.innerWidth < 834) setFilmOpen(false);
    setCompare(false);
  };
  return {
    auto,
    dispatch,
    patch,
    endEdit,
    setProfile,
    setParam,
    setInspector,
  };
}
