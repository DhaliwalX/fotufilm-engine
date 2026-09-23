import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Icon } from "../icons.jsx";
import { Text } from "@react-spectrum/s2/Text";
import { useEditor } from "./EditorContext.jsx";
export default function ViewerStatus() {
  const {
    active,
    auto,
    status,
    shownResult,
    previewKey,
    error,
    interacting,
    compare,
    setCompare,
    detailBackend,
  } = useEditor();
  return (
    <div className="viewer-status">
      <span className="document-name">{active?.name || "No photo open"}</span>
      {!active?.image.video && (
        <span role="status">
          {auto.status ||
            status ||
            (active && shownResult?.key !== previewKey
              ? error
                ? "Preview unavailable"
                : interacting
                  ? "Waiting for adjustments to settle before full-detail preview"
                  : "Waiting for the next display frame"
              : null) ||
            (shownResult
              ? `${shownResult.width} × ${shownResult.height} · ${shownResult.elapsed.toFixed(0)} ms`
              : "")}
        </span>
      )}
      {active && (
        <ActionButton
          size="S"
          UNSAFE_className={`compare-button ${compare ? "active" : ""}`}
          onPressStart={() => setCompare(true)}
          onPressEnd={() => setCompare(false)}
          onBlur={() => setCompare(false)}
          aria-label="Hold to compare with original"
          isQuiet
        >
          <Icon name="compare" />
          <Text>{"Compare"}</Text>
        </ActionButton>
      )}
      <span className="backend-label">
        {(detailBackend || shownResult?.backend) === "webgpu"
          ? "WebGPU"
          : (detailBackend || shownResult?.backend) === "Halide/Metal"
            ? "Metal"
            : shownResult
              ? "CPU"
              : ""}
      </span>
    </div>
  );
}
