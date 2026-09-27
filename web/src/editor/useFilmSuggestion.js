import { useEffect, useRef } from "react";
import { appSetting, useAppSetting } from "../app-settings.js";

// Choose Film Per Photo, as the Mac app does it: a photograph opened for the first time is
// ranked against every film and takes the best, unless its film was changed meanwhile; the film
// it settles on is recorded, so the ranking learns this person's taste.
export default function useFilmSuggestion({ backend, active, edit, dispatch }) {
  const autoFilm = useAppSetting("autoFilm");
  const current = useRef({});
  current.current = { active, edit };
  const photoID = active ? (active.libraryKey ?? active.id) : null;

  useEffect(() => {
    if (!backend.suggestFilm || !appSetting("autoFilm") || !active) return;
    if (active.image.video || active.libraryEdit || active.filmSuggested) return;
    active.filmSuggested = true;
    const startingFilm = edit.stock;
    let live = true;
    backend
      .suggestFilm({ image: active.image, edit, photoID })
      .then(({ best }) => {
        const now = current.current;
        if (!live || !best || now.active?.id !== active.id) return;
        if (now.edit.stock !== startingFilm || best === startingFilm) return;
        dispatch({ type: "replace", patch: { stock: best } });
      })
      .catch(() => {});
    return () => {
      live = false;
    };
    // Only a newly opened photograph is ranked; later edits never re-rank it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [backend, active?.id, autoFilm]);

  // The film a photograph settles on, once it has stayed a moment.
  useEffect(() => {
    if (!backend.recordFilmChoice || !photoID || !edit.stock || active?.image.video) return;
    const timer = setTimeout(
      () => backend.recordFilmChoice(photoID, edit.stock).catch(() => {}),
      1500,
    );
    return () => clearTimeout(timer);
  }, [backend, photoID, edit.stock, active]);
}
