import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Button } from "@react-spectrum/s2/Button";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Switch } from "@react-spectrum/s2/Switch";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import {
  SegmentedControl,
  SegmentedControlItem,
} from "@react-spectrum/s2/SegmentedControl";
import { memo, useRef, useState } from "react";
import { Adjustment } from "../Adjustment.jsx";
import { RAW_EXTENSIONS } from "../media-types.js";
import { suggestionName } from "../useNegativeFilmSuggestions.js";
import NegativeScanCanvas from "./NegativeScanCanvas.jsx";
import {
  ASPECTS,
  COLOUR,
  EXPOSURE,
  GRADES,
  STRAIGHTEN,
  TONE,
  aspectRatio,
  carriesColour,
  centredCrop,
  contrastForGrade,
  gradeForContrast,
  isAdjusted,
  isFramed,
  orientedAspect,
  paperOf,
  resetAdjustments,
  resetFraming,
  rotateLeft,
  toggleMirror,
} from "./recipe.js";
import "./negative-scan.css";

const ACCEPT = [".tif", ".tiff", ".png", ".jpg", ".jpeg", ".heic",
  ...RAW_EXTENSIONS.map((ext) => `.${ext}`)].join(",");

const slider = (key, label, range) => ({ key, label, ...range, def: 0 });
const SLIDERS = {
  exposure: slider("exposure", "Exposure", EXPOSURE),
  contrast: slider("contrast", "Contrast", TONE),
  grade: { key: "grade", label: "Paper Grade", ...GRADES, def: 2 },
  highlights: slider("highlights", "Highlights", TONE),
  shadows: slider("shadows", "Shadows", TONE),
  warmth: slider("warmth", "Warmth", COLOUR),
  tint: slider("tint", "Tint", COLOUR),
  straighten: slider("straighten", "Straighten", STRAIGHTEN),
};

// The Mac and iPad apps' negative-scan session: the scan read automatically or as a chosen film
// printed on a chosen receiver, its film base sampled from the frame, its light, tone and colour,
// the light source it was scanned on, and its framing. Every preview is printed by the engine;
// Import Positive opens the full-resolution print in the editor.
export default function NegativeScanDialog({ session, scans, onClose, onImport }) {
  const picker = useRef(null);
  const lightPicker = useRef(null);
  const [aspect, setAspect] = useState("Free");
  const { scan, recipe, edit, busy } = session;
  const films = scan?.films ?? [];
  const ready = !!scan && !!recipe;
  const film = ready && recipe.conversion === "film";
  const colour = ready && carriesColour(recipe, films);
  const paper = ready ? paperOf(recipe, films) : null;
  const picture = session.frame;

  function applyAspect(next) {
    setAspect(next);
    const frameAspect = orientedAspect(recipe, scan.naturalWidth, scan.naturalHeight);
    const ratio = aspectRatio(next, frameAspect);
    if (ratio) edit((current) => ({ ...current, crop: centredCrop(ratio, frameAspect) }));
  }

  return (
    <Dialog aria-label="Convert Negative" UNSAFE_className="negative-scan-dialog" isDismissible size="XL">
      <Heading>{session.file ? `Negative — ${session.file.name}` : "Convert Negative"}</Heading>
      <Content>
        <div className="negative-scan">
          <div className="negative-scan-bar">
            <ActionButton size="S" isDisabled={busy} onPress={() => picker.current?.click()}>
              Choose Negative…
            </ActionButton>
            {scans.encoding && session.file && scan && !scan.raw && (
              <Picker
                aria-label="Scan encoding"
                size="S"
                isDisabled={busy}
                value={session.linearSamples ? "linear" : "profile"}
                onChange={(value) => session.setLinearSamples(value === "linear")}
              >
                <PickerItem id="profile">Use File Colour Profile</PickerItem>
                <PickerItem id="linear">Linear Samples</PickerItem>
              </Picker>
            )}
            <span className="negative-scan-spacer" />
            <ActionButton size="S" isDisabled={!session.canUndo} onPress={session.undo}>
              Undo
            </ActionButton>
            <ActionButton size="S" isDisabled={!session.canRedo} onPress={session.redo}>
              Redo
            </ActionButton>
            <ToggleButton
              size="S"
              isDisabled={!ready || session.tab !== "convert" || session.picking}
              isSelected={session.showNegative}
              onChange={session.setShowNegative}
            >
              Show Negative
            </ToggleButton>
          </div>
          <input
            ref={picker}
            type="file"
            accept={ACCEPT}
            hidden
            onChange={(event) => {
              session.setFile(event.target.files[0] || null);
              event.target.value = "";
            }}
          />
          <div className="negative-scan-body">
            <NegativeScanCanvas
              frame={picture}
              recipe={recipe}
              mode={
                session.picking ? "border" : session.tab === "frame" ? "crop" : "view"
              }
              aspect={
                ready
                  ? aspectRatio(aspect, orientedAspect(recipe, scan.naturalWidth, scan.naturalHeight))
                  : null
              }
              onCrop={(crop) => edit((current) => ({ ...current, crop }))}
              onBorder={session.sampleBorder}
              onSize={session.setMaxEdge}
              placeholder={
                session.file ? (session.error ? "" : "Preparing preview…")
                  : "Choose a negative to convert"
              }
            />
            <div className="negative-scan-column" inert={!ready || busy}>
              <SegmentedControl
                aria-label="Negative panels"
                UNSAFE_style={{ width: "100%", flexShrink: 0 }}
                selectedKey={session.tab}
                onSelectionChange={session.setTab}
                isJustified
              >
                <SegmentedControlItem id="convert">Convert</SegmentedControlItem>
                <SegmentedControlItem id="frame">Frame</SegmentedControlItem>
              </SegmentedControl>
              {ready && session.tab === "convert" && (
                <ConvertPanel
                  session={session}
                  films={films}
                  film={film}
                  colour={colour}
                  paper={paper}
                  lightPicker={lightPicker}
                />
              )}
              {ready && session.tab === "frame" && (
                <FramePanel session={session} aspect={aspect} setAspect={applyAspect} />
              )}
            </div>
          </div>
          <input
            ref={lightPicker}
            type="file"
            accept={ACCEPT}
            hidden
            onChange={(event) => {
              const chosen = event.target.files[0];
              event.target.value = "";
              if (chosen) session.addLightFrame(chosen);
            }}
          />
          <p className="negative-scan-status" role="status">
            {session.picking ? "Drag over clear film between frames." : session.status}
          </p>
          {session.error && (
            <p role="alert" className="negative-scan-error">{session.error}</p>
          )}
          <div className="negative-scan-actions">
            <Button variant="secondary" size="S" onPress={onClose}>Cancel</Button>
            <Button
              variant="accent"
              size="S"
              isDisabled={!ready || busy}
              onPress={() => session.commit(onImport)}
            >
              Import Positive
            </Button>
          </div>
        </div>
      </Content>
    </Dialog>
  );
}

function Section({ title, children }) {
  return (
    <section className="negative-scan-section">
      <h3>{title}</h3>
      {children}
    </section>
  );
}

// A recipe slider: its run of changes is one step of history.
const RecipeSlider = memo(function RecipeSlider({ spec, value, edit, endStroke, write }) {
  return (
    <Adjustment
      slider={spec}
      value={value}
      onChange={(next) =>
        edit((current) => write ? write(current, next) : { ...current, [spec.key]: next }, {
          stroke: true,
        })
      }
      onEnd={endStroke}
    />
  );
});

function ConvertPanel({ session, films, film, colour, paper, lightPicker }) {
  const { recipe, edit, endStroke, scan } = session;
  const sliderProps = { edit, endStroke };
  const suggestions = scan.suggestions ?? [];
  return (
    <>
      <Section title="Reading">
        <Picker
          label="Method"
          size="S"
          value={recipe.conversion}
          onChange={(conversion) => edit((current) => ({ ...current, conversion }))}
        >
          <PickerItem id="automatic">Automatic</PickerItem>
          <PickerItem id="film">Film</PickerItem>
        </Picker>
        {film ? (
          <>
            <Picker
              label="Film"
              size="S"
              value={recipe.stockID}
              onChange={(stockID) => edit((current) => ({ ...current, stockID }))}
            >
              {films.map(({ id, name }) => (
                <PickerItem key={id} id={id}>{name}</PickerItem>
              ))}
            </Picker>
            <Picker
              label="Output Medium"
              size="S"
              value={paper?.id ?? null}
              onChange={(paperID) => edit((current) => ({ ...current, paperID }))}
            >
              {(films.find(({ id }) => id === recipe.stockID)?.papers ?? []).map(({ id, name }) => (
                <PickerItem key={id} id={id}>{name}</PickerItem>
              ))}
            </Picker>
          </>
        ) : (
          <Switch
            size="S"
            isSelected={recipe.monochrome}
            onChange={(monochrome) => edit((current) => ({ ...current, monochrome }))}
          >
            Black &amp; White
          </Switch>
        )}
        {suggestions.length > 0 && (
          <div className="negative-scan-suggestions">
            <span>The film base looks like</span>
            {suggestions.slice(0, 3).map((suggestion) => (
              <ActionButton
                key={suggestion.films[0].id}
                size="XS"
                isQuiet
                isDisabled={!films.some(({ id }) => id === suggestion.films[0].id)}
                onPress={() =>
                  edit((current) => ({
                    ...current,
                    conversion: "film",
                    stockID: suggestion.films[0].id,
                  }))
                }
              >
                {suggestionName(suggestion)}
              </ActionButton>
            ))}
          </div>
        )}
      </Section>
      {film && (
        <Section title="Film Base">
          <div className="negative-scan-buttons">
            <ToggleButton size="S" isSelected={session.picking} onChange={session.setPicking}>
              Pick from Frame
            </ToggleButton>
            <ActionButton
              size="S"
              isDisabled={!recipe.border}
              onPress={() =>
                edit((current) => ({ ...current, border: null, borderArea: null }))
              }
            >
              Measure
            </ActionButton>
          </div>
          <p className="negative-scan-note">
            {recipe.border ? "Sampled from the frame." : "Estimated from the thinnest film."}
          </p>
        </Section>
      )}
      <Section title="Light">
        <RecipeSlider spec={SLIDERS.exposure} value={recipe.exposure} {...sliderProps} />
        {colour ? (
          <RecipeSlider spec={SLIDERS.contrast} value={recipe.contrast} {...sliderProps} />
        ) : (
          <RecipeSlider
            spec={SLIDERS.grade}
            value={gradeForContrast(recipe.contrast)}
            write={(current, grade) => ({ ...current, contrast: contrastForGrade(grade) })}
            {...sliderProps}
          />
        )}
        <RecipeSlider spec={SLIDERS.highlights} value={recipe.highlights} {...sliderProps} />
        <RecipeSlider spec={SLIDERS.shadows} value={recipe.shadows} {...sliderProps} />
        {colour && (
          <>
            <RecipeSlider spec={SLIDERS.warmth} value={recipe.warmth} {...sliderProps} />
            <RecipeSlider spec={SLIDERS.tint} value={recipe.tint} {...sliderProps} />
          </>
        )}
        <ActionButton
          size="S"
          isQuiet
          isDisabled={!isAdjusted(recipe)}
          onPress={() => edit(resetAdjustments)}
        >
          Reset
        </ActionButton>
      </Section>
      <Section title="Light Source">
        <Picker
          aria-label="Light source"
          size="S"
          value={recipe.lightFrameID ?? "none"}
          onChange={(id) =>
            edit((current) => ({ ...current, lightFrameID: id === "none" ? null : id }))
          }
        >
          {[{ id: "none", name: "As Scanned" }, ...session.lightFrames].map(({ id, name }) => (
            <PickerItem key={id} id={id}>{name}</PickerItem>
          ))}
        </Picker>
        <div className="negative-scan-buttons">
          <ActionButton size="S" onPress={() => lightPicker.current?.click()}>
            Add Light Frame…
          </ActionButton>
          <ActionButton
            size="S"
            isDisabled={!recipe.lightFrameID}
            onPress={() => session.removeLightFrame(recipe.lightFrameID)}
          >
            Remove
          </ActionButton>
        </div>
      </Section>
      <Section title="Roll">
        <div className="negative-scan-buttons">
          <ActionButton size="S" onPress={session.copy}>Copy Conversion</ActionButton>
          <ActionButton size="S" isDisabled={!session.canPaste} onPress={session.paste}>
            Paste
          </ActionButton>
        </div>
      </Section>
    </>
  );
}

function FramePanel({ session, aspect, setAspect }) {
  const { recipe, edit, endStroke } = session;
  return (
    <>
      <Section title="Orientation">
        <div className="negative-scan-buttons">
          <ActionButton size="S" onPress={() => edit(rotateLeft)}>Rotate</ActionButton>
          <ActionButton size="S" onPress={() => edit(toggleMirror)}>Flip</ActionButton>
        </div>
        <RecipeSlider spec={SLIDERS.straighten} value={recipe.straighten} edit={edit} endStroke={endStroke} />
      </Section>
      <Section title="Crop">
        <Picker label="Aspect" size="S" value={aspect} onChange={setAspect}>
          {ASPECTS.map((id) => (
            <PickerItem key={id} id={id}>{id}</PickerItem>
          ))}
        </Picker>
        <div className="negative-scan-buttons">
          <ActionButton size="S" onPress={session.findFrame}>Find Frame</ActionButton>
          <ActionButton
            size="S"
            isDisabled={!isFramed(recipe)}
            onPress={() => {
              setAspect("Free");
              edit(resetFraming);
            }}
          >
            Reset
          </ActionButton>
        </div>
        <p className="negative-scan-note">Drag on the picture to crop.</p>
      </Section>
    </>
  );
}
