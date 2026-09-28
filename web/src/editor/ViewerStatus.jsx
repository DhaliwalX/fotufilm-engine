import { useEditor, useEditorFrame } from "./EditorContext.jsx";
// What the viewer is doing, announced to assistive technology rather than drawn: the photograph
// itself says when a preview lands, and holding the photograph or Space compares it.
export default function ViewerStatus() {
  const { active, auto, error, detailBackend } = useEditor();
  const { shownResult, status, previewKey, interacting } = useEditorFrame();
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
