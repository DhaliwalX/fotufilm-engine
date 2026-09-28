import { useCallback, useEffect, useRef, useState } from "react";

// Import Film Pack, as the Mac app's File menu has it: a community pack goes into the library
// this person's films live in, the engine reloads its films and the film list follows. Packs
// arrive from the native File menu and Finder (by path), and from drops and the Options menu
// (as files); each result reads as the Mac app's alert does ("Pack added", "Test Pack v1 — 3
// films"). A backend without `filmPacks` offers none of it.

export const FILM_PACK_EXTENSION = ".fotufilmpack";

export const isFilmPack = (name) =>
  typeof name === "string" && name.toLowerCase().endsWith(FILM_PACK_EXTENSION);

const itemName = (item) =>
  item instanceof Blob ? item.name : (item?.name ?? item?.file?.name ?? item?.path);

// One notice for everything that arrived together.
export function packNotice(results) {
  if (results.length === 1) return results[0];
  return {
    title: results.every((result) => result.added) ? "Packs added" : "Film packs",
    message: results.map(({ title, message }) => `${title}: ${message}`).join("\n\n"),
    added: results.some((result) => result.added),
    update: results.some((result) => result.update),
  };
}

export default function useFilmPacks({
  backend,
  acceptFiles,
  selectStock,
  edit,
  exporting,
  setRetry,
  setDialog,
}) {
  const filmPacks = backend.filmPacks;
  const packInput = useRef(null);
  const [notice, setNotice] = useState(null);
  const [installedPacks, setInstalledPacks] = useState(null);

  // The engine has reloaded its films: the list asks again, as it does on a retry.
  const filmsChanged = useCallback(
    (packs) => {
      backend.reloadStocks?.();
      setRetry((value) => value + 1);
      if (packs) setInstalledPacks(packs);
    },
    [backend, setRetry],
  );

  // The installed packs; `changed` means another app added or removed one and the engine has
  // reloaded its films since.
  const refreshPacks = useCallback(() => {
    if (!filmPacks) return Promise.resolve([]);
    return filmPacks.list().then(({ packs, changed }) => {
      if (changed) filmsChanged(packs);
      else setInstalledPacks(packs);
      return packs;
    });
  }, [filmPacks, filmsChanged]);

  // Resolves one result per pack; `quiet` leaves showing them to the caller (Settings shows them
  // in place), otherwise they appear as the Mac app's alert.
  async function importFilmPacks(items, { quiet = false } = {}) {
    if (!filmPacks || exporting || !items?.length) return [];
    const results = [];
    let packs;
    for (const item of items) {
      try {
        const result = item.path
          ? await filmPacks.importPath(item.path)
          : await filmPacks.importFile(item instanceof Blob ? item : item.file);
        if (result.added) packs = result.packs;
        results.push(result);
      } catch (error) {
        results.push({
          added: false,
          title: "Pack not added",
          message: `${itemName(item)}: ${error.message}`,
        });
      }
    }
    if (packs) filmsChanged(packs);
    if (!quiet) {
      setNotice(packNotice(results));
      setDialog("filmPack");
    }
    return results;
  }

  async function removeFilmPack(packID) {
    if (!filmPacks || exporting) return;
    const removed = installedPacks?.find((pack) => pack.packID === packID);
    const { packs } = await filmPacks.remove(packID);
    // A photo on one of its films goes back to no film rather than to a film that is gone.
    if (removed?.stocks?.includes(edit?.stock)) selectStock(null);
    filmsChanged(packs);
  }

  // Files a drop, the file chooser or the native host brings: packs are installed, the rest open.
  const acceptWithPacks = (incoming) => {
    const items = Array.from(incoming || []);
    const packs = filmPacks ? items.filter((item) => isFilmPack(itemName(item))) : [];
    const others = items.filter((item) => !packs.includes(item));
    if (packs.length) importFilmPacks(packs).catch(console.error);
    if (others.length || !packs.length) return acceptFiles(others);
  };

  // At launch, installed packs this release cannot read offer the update, as the Mac app does.
  useEffect(() => {
    if (!filmPacks) return;
    filmPacks
      .list()
      .then(({ incompatible }) => {
        if (!incompatible?.length) return;
        setNotice({
          title: "Update Fotufilm to use this pack",
          message: incompatible.join("\n\n"),
          added: false,
          update: true,
        });
        setDialog("filmPack");
      })
      .catch(console.error);
    refreshPacks().catch(console.error);
    // Once per launch: later refreshes only follow the list.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filmPacks]);

  // A pack the Mac app added while this window was in the background shows when it comes back,
  // unless an export holds the engine.
  const busy = useRef(exporting);
  busy.current = exporting;
  useEffect(() => {
    if (!filmPacks) return;
    const focused = () => {
      if (!busy.current) refreshPacks().catch(console.error);
    };
    window.addEventListener("focus", focused);
    return () => window.removeEventListener("focus", focused);
  }, [filmPacks, refreshPacks]);

  return {
    filmPacks,
    packInput,
    packNotice: notice,
    installedPacks,
    refreshPacks,
    importFilmPacks,
    removeFilmPack,
    openFilmPacks: () => {
      if (filmPacks && !exporting) packInput.current?.click();
    },
    acceptFiles: acceptWithPacks,
  };
}
