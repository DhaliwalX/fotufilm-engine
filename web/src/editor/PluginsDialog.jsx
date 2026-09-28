import { useEffect } from "react";
import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { Button } from "@react-spectrum/s2/Button";
import { ProgressCircle } from "@react-spectrum/s2/ProgressCircle";
import { useEditor } from "./EditorContext.jsx";

// The plug-ins for other editors a native host installs (editor.plugins, usePlugins.js): what is
// installed, from which build, and the Mac app's Plugins menu actions for each. Opened from the
// options menu, the native Plugins menu, or at launch when this build's plug-ins are not in place.

const joined = (names) =>
  names.length > 1 ? `${names.slice(0, -1).join(", ")} and ${names.at(-1)}` : names[0];

/** What a plug-in's state reads as, from its `plugins` entry. */
export function pluginStatusText(status) {
  if (!status) return "Checking…";
  const build = (version) => (version ? ` (build ${version})` : "");
  switch (status.state) {
    case "installed":
      return `Installed${build(status.installedVersion)}.`;
    case "outdated":
      return (
        `Installed from another version of Fotufilm${build(status.installedVersion)}. ` +
        `Update to install this version's${build(status.bundledVersion)}.`
      );
    case "notInstalled":
      return status.hostInstalled
        ? "Not installed."
        : `Not installed. ${status.name} is not on this computer; the plug-in can be installed ahead of it.`;
    default:
      return "This copy of Fotufilm does not contain this plug-in.";
  }
}

/** The install button's label for a plug-in's state. */
export function installLabel(status) {
  if (status?.state === "outdated") return "Update";
  if (status?.state === "installed") return "Reinstall";
  return "Install";
}

function PluginRow({ plugin, status, model }) {
  const busy = model.busy === plugin.id;
  const result = model.result?.id === plugin.id ? model.result : null;
  const installed = status && (status.state === "installed" || status.state === "outdated");
  return (
    <section className="plugin-row" aria-label={plugin.name}>
      <h3>{plugin.name}</h3>
      <p className="medium-detail">{pluginStatusText(status)}</p>
      {status?.bundledVersion && !installed && status.note && (
        <p className="medium-detail">{status.note}</p>
      )}
      <div className="plugin-actions">
        <Button
          size="S"
          variant={status?.state === "installed" ? "secondary" : "accent"}
          isDisabled={!status?.bundledVersion || !!model.busy}
          onPress={() => model.install(plugin.id)}
        >
          {busy ? "Installing…" : installLabel(status)}
        </Button>
        <Button
          size="S"
          variant="secondary"
          isDisabled={!installed}
          onPress={() => model.reveal(plugin.id)}
        >
          {"Show Installed Plug-in"}
        </Button>
        {busy && (
          <ProgressCircle aria-label={`Installing the ${plugin.name} plug-in`} isIndeterminate size="S" />
        )}
      </div>
      {result?.message && <p role="status" className="medium-detail">{result.message}</p>}
      {result?.error && <p role="alert">{result.error}</p>}
    </section>
  );
}

export default function PluginsDialog() {
  const { plugins: model, setDialog } = useEditor();
  const refresh = model?.refresh;
  // Read afresh on opening: a plug-in may have been installed or removed since.
  useEffect(() => {
    refresh?.().catch(() => {});
  }, [refresh]);
  if (!model) return null;
  const { offer } = model;
  const status = (id) => model.list?.find((entry) => entry.id === id);
  if (offer) {
    // The launch offer, worded as the Mac app's: install for a plug-in never there, update for
    // one from another build.
    const names = offer.ids.map((id) => status(id)?.name ?? id);
    const notes = offer.ids.map((id) => status(id)?.note).filter(Boolean);
    const verb = offer.updating ? "Update" : "Install";
    return (
      <Dialog aria-label="Plug-ins" size={"M"}>
        <Heading>{`${verb} the Fotufilm plug-ins for ${joined(names)}?`}</Heading>
        <Content>
          <p className="medium-detail">
            {offer.updating
              ? "The installed plug-ins are from another version of Fotufilm. Updating them keeps them developing the same film this app does."
              : `Fotufilm can develop film inside ${joined(names)} using the same engine this app uses.`}
          </p>
          {notes.map((note) => (
            <p key={note} className="medium-detail">
              {note}
            </p>
          ))}
          <div className="dialog-actions">
            <Button
              size="S"
              variant="secondary"
              onPress={() => {
                model.decline();
                setDialog(null);
              }}
            >
              {"Not Now"}
            </Button>
            <Button size="S" variant="accent" onPress={model.acceptOffer}>
              {verb}
            </Button>
          </div>
        </Content>
      </Dialog>
    );
  }
  return (
    <Dialog aria-label="Plug-ins" isDismissible size={"M"}>
      <Heading>{"Plug-ins"}</Heading>
      <Content>
        <p className="medium-detail">
          {`Fotufilm can develop film inside ${joined(model.catalogue.map(({ name }) => name))} using the same engine this app uses. Restart an editor after installing to load its plug-in.`}
        </p>
        <div className="settings-pane">
          {model.catalogue.map((plugin) => (
            <PluginRow
              key={plugin.id}
              plugin={plugin}
              status={status(plugin.id)}
              model={model}
            />
          ))}
        </div>
      </Content>
    </Dialog>
  );
}
