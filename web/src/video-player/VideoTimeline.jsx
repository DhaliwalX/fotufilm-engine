import { Slider } from "@react-spectrum/s2/Slider";
import { VIDEO_LABELS } from "../generated/controls.js";
import { videoTimeLabel } from "./time.js";

export default function VideoTimeline({
  clip,
  start,
  end,
  position,
  seek,
  disabled,
}) {
  const duration = clip.duration - clip.start;
  const trimmed = start > clip.start || end < clip.duration;
  return (
    <div className="video-timeline">
      <div className="video-time-row">
        <output aria-label="Playback time" className="video-timecode">
          <strong>{videoTimeLabel(position)}</strong>
          <span> / {videoTimeLabel(clip.duration)}</span>
        </output>
        {trimmed && (
          <span className="video-selection-label">
            {VIDEO_LABELS.selection} · {videoTimeLabel(end - start)}
          </span>
        )}
      </div>
      <Slider
        aria-label={VIDEO_LABELS.position}
        minValue={clip.start}
        maxValue={clip.duration}
        step={0.001}
        value={position}
        onChange={seek}
        isDisabled={disabled}
        size="M"
        isEmphasized
        UNSAFE_className="video-seek"
        UNSAFE_style={{ width: "100%" }}
      />
      <div
        className="video-range-guide"
        data-trimmed={trimmed}
        aria-hidden="true"
      >
        <span
          style={{
            left: `${(100 * (start - clip.start)) / duration}%`,
            width: `${(100 * (end - start)) / duration}%`,
          }}
        />
      </div>
    </div>
  );
}
