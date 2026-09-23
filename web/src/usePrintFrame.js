import { useBackend } from "./backend/BackendContext.jsx";
import { useEffect, useState } from "react";
import { frameRequest } from "./print-frame.js";

// A keyed result prevents a slow old request from describing a newer frame or file.
export function usePrintFrame(edit, width = 1, height = 1, enabled = true) {
  const backend = useBackend();
  const key =
    enabled && width > 0 && height > 0
      ? JSON.stringify(frameRequest(edit, width, height))
      : null;
  const [state, setState] = useState(null);
  useEffect(() => {
    if (!key) return;
    let current = true;
    const request = JSON.parse(key);
    backend.planPrintFrame(
      {
        stock: request.stock,
        printFrame: request.frame,
        format: request.format,
        medium: request.medium,
        profile: edit.profile,
      },
      width,
      height,
    )
      .then((plan) => {
        if (current) setState({ key, plan });
      })
      .catch((error) => {
        if (current) setState({ key, error: error.message });
      });
    return () => {
      current = false;
    };
  }, [key]);
  return state?.key === key ? state : { pending: !!key };
}
