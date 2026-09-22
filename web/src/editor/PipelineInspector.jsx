const stageNames = [
  "Bypass",
  "Exposure",
  "Flare",
  "Diffusion",
  "Halation",
  "Couplers",
  "Development",
  "Grain",
  "Negative",
  "Output",
];

import { Switch } from "@react-spectrum/s2/Switch";
import { hasProfileSettings } from "../profile-settings.js";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useEditor } from "./EditorContext.jsx";
export default function PipelineInspector() {
  const { edit, stage, setStage, setDifference, stages, difference, result } =
    useEditor();
  return (
    <>
      <div className="inspector-title">
        <h2>Pipeline</h2>
      </div>
      {hasProfileSettings(edit) && (
        <p className="inspector-hint">
          Individual pipeline stages are available with the film’s default film,
          print and filter settings.
        </p>
      )}
      <div className="pipeline-list">
        <ActionButton
          size="S"
          UNSAFE_className={stage === null ? "selected" : ""}
          onPress={() => {
            setStage(null);
            setDifference(false);
          }}
          isQuiet
        >
          {"Finished print"}
        </ActionButton>
        {stages.map((item, i) => (
          <ActionButton
            key={item.id}
            UNSAFE_className={stage === i ? "selected" : ""}
            onPress={() => setStage(i)}
            isDisabled={!edit.stock}
            size={"S"}
          >
            <span>{String(i + 1).padStart(2, "0")}</span>
            {stageNames[i] || item.label}
          </ActionButton>
        ))}
      </div>
      <Switch
        isSelected={difference}
        onChange={(e) => setDifference(e)}
        isDisabled={stage === null || stage === 0}
        size={"S"}
        UNSAFE_className={"toggle-row"}
      >
        <span>Show stage difference</span>
      </Switch>
      {result?.delta && (
        <p className="inspector-hint">
          {result.delta.gain.toFixed(1)}× gain · {result.delta.peak}
          /255 peak
        </p>
      )}
    </>
  );
}
