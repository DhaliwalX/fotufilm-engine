import { useCallback, useMemo, useSyncExternalStore } from "react";

export default function useCompactLayout() {
  const query = useMemo(() => window.matchMedia("(max-width: 833px)"), []);
  const subscribe = useCallback(
    (notify) => {
      query.addEventListener("change", notify);
      return () => query.removeEventListener("change", notify);
    },
    [query],
  );
  return useSyncExternalStore(
    subscribe,
    () => query.matches,
    () => false,
  );
}
