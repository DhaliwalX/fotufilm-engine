import { useCallback, useEffect, useRef, useState } from "react";
import { appSetting, setAppSetting } from "../app-settings.js";

// The plug-ins for other editors a native host installs (backend.plugins: DaVinci Resolve and
// Final Cut Pro on the Mac), as the Mac app's Plugins menu and launch offer handle them. The
// state is read from the host when the editor opens, when its window comes back to the front and
// after every install, since a plug-in can be installed or removed behind the editor's back.

// The plug-ins worth offering at launch: carried by this build, not installed as this build's, and
// for an editor that is on this computer.
export function pluginsToOffer(list) {
  return (list ?? []).filter(
    ({ state, hostInstalled, bundledVersion }) =>
      bundledVersion &&
      hostInstalled &&
      (state === "notInstalled" || state === "outdated"),
  );
}

// The launch offer, unless this build's was declined: the plug-ins and whether all are updates.
export function launchOffer(list, declined) {
  const pending = pluginsToOffer(list);
  if (!pending.length) return null;
  const version = pending[0].bundledVersion;
  if (declined === version) return null;
  return {
    ids: pending.map(({ id }) => id),
    version,
    updating: pending.every(({ state }) => state === "outdated"),
  };
}

export default function usePlugins({ backend, dialog, setDialog }) {
  const available = !!backend.plugins?.length;
  const [list, setList] = useState(null);
  const [busy, setBusy] = useState(null);
  const [result, setResult] = useState(null);
  const [offer, setOffer] = useState(null);
  const offered = useRef(false);
  const latestDialog = useRef(dialog);
  latestDialog.current = dialog;

  const refresh = useCallback(async () => {
    if (!available) return null;
    const next = await backend.pluginStatus();
    setList(next);
    return next;
  }, [backend, available]);

  const install = useCallback(
    async (id) => {
      if (!available) return;
      setBusy(id);
      setResult(null);
      try {
        const { message, plugins } = await backend.installPlugin(id);
        if (plugins) setList(plugins);
        setResult({ id, message });
      } catch (error) {
        setResult({ id, error: error?.message ?? String(error) });
        refresh().catch(() => {});
      } finally {
        setBusy(null);
      }
    },
    [backend, available, refresh],
  );

  const installAll = useCallback(
    async (ids) => {
      for (const id of ids) await install(id);
    },
    [install],
  );

  const reveal = useCallback(
    (id) =>
      backend.revealPlugin(id).catch((error) =>
        setResult({ id, error: error?.message ?? String(error) }),
      ),
    [backend],
  );

  // Declining is remembered against this build, as the Mac app remembers it: a later build asks
  // again, because a later build is a different question.
  const decline = useCallback(() => {
    if (offer) setAppSetting("pluginOfferDeclined", offer.version);
    setOffer(null);
  }, [offer]);

  const acceptOffer = useCallback(() => {
    if (!offer) return;
    setAppSetting("pluginOfferDeclined", null);
    const { ids } = offer;
    setOffer(null);
    installAll(ids);
  }, [offer, installAll]);

  useEffect(() => {
    if (!available) return;
    let live = true;
    refresh()
      .then((next) => {
        if (!live || offered.current) return;
        offered.current = true;
        const pending = launchOffer(next, appSetting("pluginOfferDeclined"));
        // Only over an empty editor: a dialog already up is the person's, not ours to replace.
        if (!pending || latestDialog.current) return;
        setOffer(pending);
        setDialog("plugins");
      })
      .catch(() => {});
    const focus = () => refresh().catch(() => {});
    window.addEventListener("focus", focus);
    return () => {
      live = false;
      window.removeEventListener("focus", focus);
    };
  }, [available, refresh, setDialog]);

  // The offer belongs to the dialog it opened; closed any other way, it is left for next launch.
  useEffect(() => {
    if (dialog !== "plugins") setOffer(null);
  }, [dialog]);

  return {
    plugins: available
      ? {
          catalogue: backend.plugins,
          list,
          busy,
          result,
          offer,
          refresh,
          install,
          reveal,
          acceptOffer,
          decline,
        }
      : null,
  };
}
