import { useRef, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { importLensCatalogue, removeLensCatalogue } from "./lens-catalogue.js";
import { useLensCatalogue } from "./useLensCatalogue.js";

export default function LensProfileLibrary({ disabled }) {
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
      const count = await importLensCatalogue(file, setProgress);
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
    <details className="lens-profile-library">
      <summary>
        Lens Profiles
        {catalogue.profiles.length ? ` · ${catalogue.profiles.length}` : ""}
      </summary>
      <div className="lens-profile-actions motion-fade-in">
        <p className="medium-detail">
          Import measured profiles in Fotufilm’s JSON format. Matching profiles
          are selected from each photo’s lens metadata and saved in this
          browser.
        </p>
        <input
          ref={input}
          type="file"
          accept="application/json,.json"
          aria-label="Import lens profiles"
          hidden
          onChange={(event) => importProfiles(event.target.files[0])}
        />
        <Button
          label="Import Lens Profiles…"
          size="sm"
          variant="ghost"
          isDisabled={disabled || busy}
          onClick={() => input.current.click()}
        />
        {!!catalogue.profiles.length && (
          <Button
            label="Remove Imported Profiles"
            size="sm"
            variant="ghost"
            isDisabled={disabled || busy}
            onClick={async () => {
              setBusy(true);
              setError(null);
              try {
                await removeLensCatalogue();
                setProgress("Imported lens profiles removed.");
              } catch (error) {
                setError(error.message);
              } finally {
                setBusy(false);
              }
            }}
          />
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
    </details>
  );
}
