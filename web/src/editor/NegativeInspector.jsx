import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { useEffect, useRef, useState } from "react";
import { NEGATIVE_ACCEPT } from "../media-types.js";
import { readsNegative, suggestionName } from "../negative-document.js";
import { useEditor } from "./EditorContext.jsx";

function Section({ title, children }) {
  return (
    <Disclosure defaultExpanded={true} size={"S"} isQuiet UNSAFE_className={"inspector-section"}>
      <DisclosureTitle>{title}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">{children}</div>
      </DisclosurePanel>
    </Disclosure>
  );
}

// A scanned negative's Film panel: what the scan is read as. The film is chosen in the film
// library; here are the films its base looks like, the clear film it is measured against and the
// light source it was scanned on. The print is the Print panel's.
export default function NegativeInspector() {
  const {
    backend,
    active,
    edit,
    patch,
    endEdit,
    stocks,
    selectedStock,
    selectStock,
    sampling,
    setSampling,
    exporting,
    setError,
  } = useEditor();
  const scans = backend.negativeScans;
  const negative = edit.negative;
  const lightFrames = useLightFrames(scans, active?.image.negative?.lightFrames);
  const lightPicker = useRef(null);
  // The panel's exit transition can outlive the document it showed.
  if (!negative) return null;
  const installed = new Set(stocks.filter(readsNegative).map(({ id }) => id));
  const suggestions = (active?.image.negative?.suggestions ?? []).filter(({ films }) =>
    installed.has(films[0].id),
  );
  const disabled = exporting || !active;
  const read = (change) => {
    endEdit();
    patch({ negative: { ...negative, ...change } });
  };
  async function addLightFrame(file) {
    try {
      const added = await lightFrames.add(file);
      read({ lightFrame: added.id });
    } catch (failure) {
      setError(failure.message);
    }
  }
  return (
    <>
      <Section title="Negative">
        <div className="info-row">
          <span>Film</span>
          <span>{selectedStock?.name ?? "Normal"}</span>
        </div>
        {suggestions.length > 0 && (
          <div className="info-row">
            <span>Base looks like</span>
          </div>
        )}
        {suggestions.slice(0, 3).map((suggestion) => (
          <ActionButton
            key={suggestion.films[0].id}
            size="S"
            isQuiet
            isDisabled={disabled || edit.stock === suggestion.films[0].id}
            onPress={() => selectStock(suggestion.films[0].id)}
          >
            {suggestionName(suggestion)}
          </ActionButton>
        ))}
      </Section>
      <Section title="Film Base">
        <div className="info-row">
          <span>Clear film</span>
          <span>{negative.border ? "Sampled" : "Estimated"}</span>
        </div>
        <ToggleButton
          size="S"
          isDisabled={disabled}
          isSelected={sampling === "filmBase"}
          onChange={(on) => setSampling(on ? "filmBase" : false)}
        >
          Pick Clear Film
        </ToggleButton>
        <ActionButton
          size="S"
          isDisabled={disabled || !negative.border}
          onPress={() => read({ border: null })}
        >
          Estimate
        </ActionButton>
      </Section>
      {scans.lightFrames && <Section title="Light Source">
        <Picker
          aria-label="Light source"
          size="S"
          isDisabled={disabled}
          value={negative.lightFrame ?? "none"}
          onChange={(id) => read({ lightFrame: id === "none" ? null : id })}
          UNSAFE_style={{ width: "100%" }}
        >
          {[{ id: "none", name: "As Scanned" }, ...lightFrames.list].map(({ id, name }) => (
            <PickerItem key={id} id={id}>{name}</PickerItem>
          ))}
        </Picker>
        <ActionButton size="S" isDisabled={disabled} onPress={() => lightPicker.current?.click()}>
          Add Light Frame…
        </ActionButton>
        <ActionButton
          size="S"
          isDisabled={disabled || !negative.lightFrame}
          onPress={async () => {
            await lightFrames.remove(negative.lightFrame);
            read({ lightFrame: null });
          }}
        >
          Remove Light Frame
        </ActionButton>
        <input
          ref={lightPicker}
          type="file"
          accept={NEGATIVE_ACCEPT}
          hidden
          onChange={(event) => {
            const chosen = event.target.files[0];
            event.target.value = "";
            if (chosen) addLightFrame(chosen);
          }}
        />
      </Section>}
    </>
  );
}

// The light frames the host keeps, as the scan opened with them and as they change.
function useLightFrames(scans, opened) {
  const [list, setList] = useState(opened ?? []);
  useEffect(() => {
    let live = true;
    scans
      ?.lightFrames?.()
      .then((frames) => live && setList(frames))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [scans]);
  return {
    list,
    async add(file) {
      const added = await scans.addLightFrame(file);
      setList(await scans.lightFrames());
      return added;
    },
    async remove(id) {
      await scans.removeLightFrame(id);
      setList(await scans.lightFrames());
    },
  };
}
