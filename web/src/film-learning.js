import { useEffect, useSyncExternalStore } from "react";

// How many film choices the backend has learned from (`filmChoiceCount`), so Forget What I've
// Taught It and Reset Film Suggestions stand greyed with nothing to forget, as the Mac app's do.
// Null until the backend has said; a backend without the count leaves them always available.
let count = null;
const listeners = new Set();

function set(next) {
  if (next === count) return;
  count = next;
  for (const listener of listeners) listener();
}

export function refreshFilmLearning(backend) {
  backend?.filmChoiceCount?.().then(set).catch(() => {});
}

// Forgetting leaves nothing learned; a recorded choice answers the new count.
export const forgotFilmChoices = () => set(0);
export const recordedFilmChoice = (answer) => {
  if (Number.isFinite(answer?.observations)) set(answer.observations);
};

// Whether there is anything to forget.
export function useFilmLearned(backend) {
  useEffect(() => refreshFilmLearning(backend), [backend]);
  const learned = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => count,
  );
  return learned === null ? !!backend?.forgetFilmChoices : learned > 0;
}
