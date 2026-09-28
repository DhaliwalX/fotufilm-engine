// Playback Quality and the clip summary under the transport, as the Mac app's video preview
// offers them (desktop/FotufilmApp/SessionVideoPreview.swift, VideoPreviewSimulator.Quality).

export const PLAYBACK_QUALITIES = [
  { id: "draft", label: "Draft", edge: 640 },
  { id: "standard", label: "Standard", edge: 1280 },
  { id: "fine", label: "Fine", edge: 1920 },
  { id: "full", label: "Full · 4K", edge: 3840 },
];

export const PLAYBACK_QUALITY_HELP =
  "Playback develops at this quality; the paused frame always develops at full resolution.";

/** The long edge a playing movie develops at. */
export const playbackEdge = (id) =>
  (PLAYBACK_QUALITIES.find((quality) => quality.id === id) ?? PLAYBACK_QUALITIES[2]).edge;

/** "24 fps", "29.97 fps", or "Variable fps" for a clip that names no rate. */
export function frameRateLabel(rate) {
  if (!(rate > 0)) return "Variable fps";
  return Math.round(rate) === rate ? `${rate} fps` : `${rate.toFixed(2)} fps`;
}

/** The line under the transport: the clip's frame size, rate, and whether it has sound. */
export function clipSummary({ width, height, frameRate, audio }) {
  return [
    width && height ? `${width} × ${height}` : "",
    frameRateLabel(frameRate),
    audio ? "audio" : "",
  ]
    .filter(Boolean)
    .join("   ");
}
