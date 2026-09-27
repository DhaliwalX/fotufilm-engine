import { useState } from "react";
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

// The Mac app's Settings window: what new photographs start on, how photos export, and the film
// model. Everything here is kept on this device; open photographs keep their own edits.
const PANES = [
  { id: "general", title: "General" },
  { id: "output", title: "Output" },
  { id: "filmModel", title: "Film Model" },
];
const FILM_MODEL = ["grainModel", "halationModel", "estimatedHalation"];

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
      {backend.videoExportTypes?.some(({ hdr }) => hdr) && (
        <>
          <h3>Video</h3>
          <SettingSwitch label="HDR" setting="videoHDR" />
          <p className="medium-detail">
            HEVC and ProRes movies of films that deliver HDR are written as
            HLG; H.264 stays standard.
          </p>
        </>
      )}
    </>
  );
}

function FilmModel() {
  const grain = useAppSetting("grainModel"),
    halation = useAppSetting("halationModel"),
    estimated = useAppSetting("estimatedHalation");
  const adjusted =
    grain !== APP_SETTINGS.grainModel ||
    halation !== APP_SETTINGS.halationModel ||
    estimated !== APP_SETTINGS.estimatedHalation;
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
