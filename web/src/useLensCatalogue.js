import { useEffect, useSyncExternalStore } from "react";
import { useBackend } from "./backend/BackendContext.jsx";

export function useLensCatalogue() {
  const { lenses } = useBackend();
  const catalogue = useSyncExternalStore(lenses.subscribe, lenses.snapshot);
  useEffect(() => {
    lenses.load();
  }, []);
  return catalogue;
}
