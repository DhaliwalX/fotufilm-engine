import { useEffect, useSyncExternalStore } from "react";
import {
  lensCatalogueSnapshot,
  loadLensCatalogue,
  subscribeLensCatalogue,
} from "./lens-catalogue.js";

export function useLensCatalogue() {
  const catalogue = useSyncExternalStore(
    subscribeLensCatalogue,
    lensCatalogueSnapshot,
  );
  useEffect(() => {
    loadLensCatalogue();
  }, []);
  return catalogue;
}
