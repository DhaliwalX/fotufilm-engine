import { useEffect, useState } from "react";
import { useBackend } from "./backend/BackendContext.jsx";

// The films a scan's clear base suggests, read once per scan. Hosts without
// suggestions offer none.
export function useNegativeFilmSuggestions(scan) {
  const backend = useBackend();
  const [read, setRead] = useState({ scan: null, suggestions: [] });
  useEffect(() => {
    if (!scan || !backend.suggestNegativeFilms) return;
    let current = true;
    const settle = (suggestions) => {
      if (current) setRead({ scan, suggestions });
    };
    backend.suggestNegativeFilms(scan).then(settle, () => settle([]));
    return () => {
      current = false;
    };
  }, [backend, scan]);
  return read.scan === scan ? read.suggestions : [];
}

// "Gold 200", "Vision3 500T or CineStill 800T", "Tri-X 400 and 7 similar films".
export function suggestionName({ films }) {
  return films.length > 2
    ? `${films[0].name} and ${films.length - 1} similar films`
    : films.map((film) => film.name).join(" or ");
}
