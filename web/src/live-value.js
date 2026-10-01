import { useSyncExternalStore } from "react";

// A value that changes faster than the editor should render, such as the zoom readout while a
// pinch moves: the components that show it subscribe, and nothing else renders again.
export function createLiveValue(initial) {
  let value = initial;
  const listeners = new Set();
  return {
    get: () => value,
    set(next) {
      if (Object.is(next, value)) return;
      value = next;
      for (const listener of listeners) listener();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

export function useLiveValue(live) {
  return useSyncExternalStore(live.subscribe, live.get);
}
