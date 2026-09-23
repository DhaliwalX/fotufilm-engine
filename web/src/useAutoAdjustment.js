import { useBackend } from "./backend/BackendContext.jsx";
import { useCallback, useEffect, useRef, useState } from "react";
import { AutoAdjustmentController } from "./auto-adjustment.js";
import { historyReducer } from "./editor-state.js";

export function useAutoAdjustment({
  image,
  session,
  history,
  dispatch,
  disabled,
  onError,
  onApplied,
}) {
  const backend = useBackend();
  const [state, setState] = useState({
    active: false,
    busy: false,
    status: null,
  });
  const latest = useRef(null),
    owner = useRef(null);
  latest.current = {
    image,
    session,
    history,
    dispatch,
    disabled,
    onError,
    onApplied,
  };
  if (!owner.current)
    owner.current = new AutoAdjustmentController({
      solve: (request) => backend.autoAdjust(request),
      snapshot: () => latest.current,
      onState: setState,
      onError: (message) => latest.current.onError(message),
      apply: (values) => {
        const current = latest.current;
        current.dispatch({ type: "end" });
        current.dispatch({
          type: "edit",
          patch: { params: { ...current.history.present.params, ...values } },
        });
        current.onApplied?.();
      },
    });
  useEffect(() => {
    owner.current.cancel();
    return () => owner.current.cancel(false);
  }, [image]);
  useEffect(() => {
    if (disabled && owner.current.state.busy) owner.current.cancel();
  }, [disabled]);
  const editDispatch = useCallback((action) => {
    const current = latest.current,
      before = current.history,
      after = historyReducer(before, action);
    current.history = after;
    current.dispatch(action);
    owner.current.changed(action, before, after);
  }, []);
  const toggle = useCallback(() => owner.current.toggle(), []);
  return {
    ...state,
    toggle,
    dispatch: editDispatch,
    available: !!image && !image.video && !!session && !disabled,
  };
}
