export function createLenses(call) {
  let state = { profiles: [], revision: 0, loaded: false }, ready;
  const listeners = new Set();
  const publish = (patch) => {
    state = { ...state, ...patch, revision: state.revision + 1 };
    for (const listener of listeners) listener();
    return state;
  };
  const load = () => ready ??= call("lensCatalogue").then(
    (profiles) => publish({ profiles, loaded: true, error: null }),
    (error) => { ready = null; publish({ loaded: true, error: error.message }); throw error; },
  );
  return {
    snapshot: () => state,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    load,
    async import(file) {
      if (file.size > 6 * 1024 * 1024) throw new Error("Choose a lens catalogue smaller than 6 MB.");
      const profiles = JSON.parse(await file.text());
      if (!Array.isArray(profiles) || !profiles.length) throw new Error("Choose a Fotufilm lens-profile JSON catalogue.");
      const count = await call("importLensCatalogue", { profiles });
      ready = null; await load(); return count;
    },
    async remove() { await call("removeLensCatalogue"); ready = null; await load(); },
  };
}
