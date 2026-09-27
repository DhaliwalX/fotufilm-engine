import { useEffect, useRef, useState } from "react";
import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { PickerItem, Picker } from "@react-spectrum/s2/Picker";
import {
  SegmentedControl,
  SegmentedControlItem,
} from "@react-spectrum/s2/SegmentedControl";
import { Switch } from "@react-spectrum/s2/Switch";
import { Button } from "@react-spectrum/s2/Button";
import { FILM_FORMATS } from "../generated/controls.js";
import { editorControl } from "../editor-catalogue.js";
import {
  APP_SETTINGS,
  resetAppSettings,
  setAppSetting,
  useAppSetting,
} from "../app-settings.js";
import { useEditor } from "./EditorContext.jsx";
import { Adjustment } from "../Adjustment.jsx";
import { FILM_PACK_EXTENSION, packNotice } from "./useFilmPacks.js";

// The Mac app's Settings window: what new photographs start on, how photos export, and the film
// model. Everything here is kept on this device; open photographs keep their own edits.
const PANES = [
  { id: "general", title: "General" },
  { id: "output", title: "Output" },
  { id: "filmModel", title: "Film Model" },
];
const FILM_MODEL = [
  "grainModel",
  "halationModel",
  "estimatedHalation",
  "couplerReach",
  "couplerSelf",
];

function SettingSlider({ label, setting }) {
  const value = useAppSetting(setting);
  return (
    <Adjustment
      slider={{ key: setting, label, min: 0, max: 3, step: 0.1 }}
      value={value}
      onChange={(next) => setAppSetting(setting, Math.round(next * 10) / 10)}
    />
  );
}

function SettingPicker({ label, setting, options }) {
  const value = useAppSetting(setting);
  return (
    <div className="select-row">
      {label}
      <Picker
        aria-label={label}
        value={value ?? "default"}
        onChange={(id) => setAppSetting(setting, id === "default" ? null : id)}
        size={"S"}
      >
        {options.map(({ id, label }) => (
          <PickerItem key={id} id={id}>
            {label}
          </PickerItem>
        ))}
      </Picker>
    </div>
  );
}

function SettingSwitch({ label, setting }) {
  const value = useAppSetting(setting);
  return (
    <Switch isSelected={value} onChange={(next) => setAppSetting(setting, next)}>
      {label}
    </Switch>
  );
}

// The community packs installed where this person's films live: add more, or take one away with
// its films.
function FilmPacks() {
  const { installedPacks, refreshPacks, importFilmPacks, removeFilmPack, exporting } =
    useEditor();
  const input = useRef(null);
  const [notice, setNotice] = useState(null);
  const [busy, setBusy] = useState(false);
  // Read afresh each time: another app may have added one since.
  useEffect(() => {
    refreshPacks().catch(console.error);
  }, [refreshPacks]);
  const run = async (work, failure) => {
    setBusy(true);
    try {
      setNotice(await work());
    } catch (error) {
      setNotice({ title: failure, message: error.message });
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <h3>Film Packs</h3>
      {installedPacks?.length ? (
        <ul className="film-packs" aria-label="Installed film packs">
          {installedPacks.map((pack) => (
            <li key={pack.packID}>
              <span>
                {pack.version ? `${pack.name} v${pack.version}` : pack.name}
                <small>{pack.problem ?? pack.films.join(", ")}</small>
              </span>
              <Button
                size="S"
                variant={"secondary"}
                aria-label={`Remove ${pack.name}`}
                isDisabled={busy || exporting}
                onPress={() =>
                  run(() => removeFilmPack(pack.packID).then(() => null), "Pack not removed")
                }
              >
                {"Remove"}
              </Button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="medium-detail">No film packs are installed.</p>
      )}
      <Button
        size="S"
        variant={"secondary"}
        isDisabled={busy || exporting}
        onPress={() => input.current?.click()}
      >
        {"Import Film Pack…"}
      </Button>
      <input
        ref={input}
        type="file"
        accept={FILM_PACK_EXTENSION}
        multiple
        hidden
        onChange={(e) => {
          const files = Array.from(e.target.files);
          e.target.value = "";
          run(
            async () => packNotice(await importFilmPacks(files, { quiet: true })),
            "Pack not added",
          );
        }}
      />
      {notice && (
        <p className="medium-detail film-pack-notice" role="status">
          {`${notice.title} — ${notice.message}`}
        </p>
      )}
    </>
  );
}

const choices = (field) =>
  editorControl(field).choices.map(({ id, label }) => ({ id, label }));

function General({ backend, stocks }) {
  const [forgotten, setForgotten] = useState(false);
  return (
    <>
      <h3>New Photos</h3>
      <SettingPicker
        label="Starting Film"
        setting="startingFilm"
        options={[
          { id: "default", label: "Current Film" },
          { id: "none", label: "Normal" },
          ...stocks.map(({ id, name }) => ({ id, label: name })),
        ]}
      />
      <SettingPicker
        label="Film Format"
        setting="startingFormat"
        options={[
          { id: "default", label: "Match the Film" },
          ...FILM_FORMATS.map(({ id, name }) => ({ id, label: name })),
        ]}
      />
      {backend.suggestFilm && (
        <>
          <SettingSwitch label="Suggest a Film Automatically" setting="autoFilm" />
          <p className="medium-detail">
            Suggests a film when you open a photo, based on your previous
            choices. You can select a different film at any time.
          </p>
        </>
      )}
      {backend.forgetFilmChoices && (
        <Button
          size="S"
          variant={"secondary"}
          isDisabled={forgotten}
          onPress={() =>
            backend
              .forgetFilmChoices()
              .then(() => setForgotten(true))
              .catch(console.error)
          }
        >
          {forgotten ? "Film Suggestions Reset" : "Reset Film Suggestions"}
        </Button>
      )}
      {backend.filmPacks && <FilmPacks />}
      <h3>Reset</h3>
      <Button size="S" variant={"negative"} onPress={resetAppSettings}>
        {"Reset All Settings"}
      </Button>
      <p className="medium-detail">
        Restores Fotufilm’s original settings. Your photographs and edits are not
        changed.
      </p>
    </>
  );
}

function Output({ backend }) {
  const videoHDR = backend.videoExportTypes?.some(({ hdr }) => hdr);
  return (
    <>
      <h3>Photos</h3>
      {backend.exportOptions ? (
        <>
          <SettingSwitch label="HDR" setting="photoHDR" />
          <p className="medium-detail">
            HDR preserves brighter highlights on compatible displays. Choose
            Standard for wider compatibility. It applies to HEIC exports of
            films that deliver HDR, without a print frame.
          </p>
        </>
      ) : (
        <p className="medium-detail">
          This engine exports photos in standard dynamic range.
        </p>
      )}
      {backend.exportOptions && (
        <>
          <SettingPicker
            label="Photo Quality"
            setting="photoQuality"
            options={[
              { id: "accurate", label: "Accurate" },
              { id: "fast", label: "Fast" },
            ]}
          />
          <p className="medium-detail">
            Accurate uses exact film curves. Fast uses an approximation to
            reduce processing time.
          </p>
        </>
      )}
      {(backend.videoBitrates || videoHDR) && <h3>Video</h3>}
      {videoHDR && (
        <>
          <SettingSwitch label="HDR" setting="videoHDR" />
          <p className="medium-detail">
            HEVC and ProRes movies of films that deliver HDR are written as
            HLG; H.264 stays standard.
          </p>
        </>
      )}
      {backend.videoBitrates && (
        <>
          <SettingPicker
            label="Video File Size"
            setting="videoBitrate"
            options={backend.videoBitrates}
          />
          <p className="medium-detail">
            Automatic lets the encoder choose. ProRes keeps its own rate.
          </p>
        </>
      )}
    </>
  );
}

function FilmModel() {
  const values = {
    grainModel: useAppSetting("grainModel"),
    halationModel: useAppSetting("halationModel"),
    estimatedHalation: useAppSetting("estimatedHalation"),
    couplerReach: useAppSetting("couplerReach"),
    couplerSelf: useAppSetting("couplerSelf"),
  };
  const adjusted = FILM_MODEL.some((key) => values[key] !== APP_SETTINGS[key]);
  return (
    <>
      <h3>Grain</h3>
      <SettingPicker
        label={editorControl("grainModel").title}
        setting="grainModel"
        options={choices("grainModel")}
      />
      <p className="medium-detail">
        Standard uses fast calibrated RMS noise, and Film lays the stock’s
        crystals at fixed places on the emulsion.
      </p>
      <h3>Halation</h3>
      <SettingPicker
        label={editorControl("halationModel").title}
        setting="halationModel"
        options={choices("halationModel")}
      />
      <SettingSwitch
        label={editorControl("estimatedHalation").title}
        setting="estimatedHalation"
      />
      <p className="medium-detail">
        Layered Transport simulates light moving through the film layers.
        Films with donor layers and custom film settings use Legacy. Estimated
        Halation Shape only affects Legacy.
      </p>
      <h3>Color Separation</h3>
      <SettingSlider
        label={editorControl("couplerReach").title}
        setting="couplerReach"
      />
      <SettingSlider
        label={editorControl("couplerSelf").title}
        setting="couplerSelf"
      />
      <p className="medium-detail">
        Separation sets how strongly neighboring film layers affect each other
        during development. Edge Contrast controls sharpening caused by
        development.
      </p>
      <p className="medium-detail">
        These apply to photos you open from now on; each open photo keeps its
        own.
      </p>
      <Button
        size="S"
        variant={"negative"}
        isDisabled={!adjusted}
        onPress={() =>
          FILM_MODEL.forEach((key) => setAppSetting(key, APP_SETTINGS[key]))
        }
      >
        {"Restore Film Model"}
      </Button>
    </>
  );
}

export default function SettingsDialog() {
  const { backend, stocks } = useEditor();
  const [pane, setPane] = useState("general");
  return (
    <Dialog aria-label="Settings" isDismissible size={"M"}>
      <Heading>{"Settings"}</Heading>
      <Content>
        <SegmentedControl
          aria-label="Settings panes"
          UNSAFE_style={{ width: "100%" }}
          selectedKey={pane}
          onSelectionChange={setPane}
          isJustified
        >
          {PANES.map(({ id, title }) => (
            <SegmentedControlItem key={id} id={id}>
              {title}
            </SegmentedControlItem>
          ))}
        </SegmentedControl>
        <div className="settings-pane">
          {pane === "general" ? (
            <General backend={backend} stocks={stocks} />
          ) : pane === "output" ? (
            <Output backend={backend} />
          ) : (
            <FilmModel />
          )}
        </div>
      </Content>
    </Dialog>
  );
}
