import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useRef, useState } from "react";
import { useBackend } from "./backend/BackendContext.jsx";
import { useLensCatalogue } from "./useLensCatalogue.js";
export default function LensProfileLibrary({ disabled }) {
  const { lenses } = useBackend();
  const catalogue = useLensCatalogue(),
    input = useRef(null);
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(null),
    [progress, setProgress] = useState(null);
  async function importProfiles(file) {
    if (!file) return;
    setBusy(true);
    setError(null);
    try {
      const count = await lenses.import(file, setProgress);
      setProgress(
        `${count} lens ${count === 1 ? "profile" : "profiles"} imported.`,
      );
    } catch (error) {
      setError(error.message);
      setProgress(null);
    } finally {
      setBusy(false);
      if (input.current) input.current.value = "";
    }
  }
  return (
    <Disclosure size="S" isQuiet UNSAFE_className="lens-profile-library">
      <DisclosureTitle>
        Lens Profiles
        {catalogue.profiles.length ? ` · ${catalogue.profiles.length}` : ""}
      </DisclosureTitle>
      <DisclosurePanel>
        <div className="lens-profile-actions motion-fade-in">
          <p className="medium-detail">
            Import measured profiles in Fotufilm’s JSON format. Matching
            profiles are selected from each photo’s lens metadata and saved in
            this browser.
          </p>
          <input
            ref={input}
            type="file"
            accept="application/json,.json"
            aria-label="Import lens profiles"
            hidden
            onChange={(event) => importProfiles(event.target.files[0])}
          />
          <ActionButton
            size="S"
            isDisabled={disabled || busy}
            onPress={() => input.current.click()}
            isQuiet
          >
            {"Import Lens Profiles…"}
          </ActionButton>
          {!!catalogue.profiles.length && (
            <ActionButton
              size="S"
              isDisabled={disabled || busy}
              onPress={async () => {
                setBusy(true);
                setError(null);
                try {
                  await lenses.remove();
                  setProgress("Imported lens profiles removed.");
                } catch (error) {
                  setError(error.message);
                } finally {
                  setBusy(false);
                }
              }}
              isQuiet
            >
              {"Remove Imported Profiles"}
            </ActionButton>
          )}
          {progress && (
            <p className="medium-detail" role="status">
              {progress}
            </p>
          )}
          {(error || catalogue.error) && (
            <p className="medium-detail" role="alert">
              {error || catalogue.error}
            </p>
          )}
        </div>
      </DisclosurePanel>
    </Disclosure>
  );
}
