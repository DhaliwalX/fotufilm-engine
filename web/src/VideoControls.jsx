import { Switch } from "@react-spectrum/s2/Switch";
import { NumberField } from "@react-spectrum/s2/NumberField";
import { PickerItem, Picker } from "@react-spectrum/s2/Picker";
import { Slider } from "@react-spectrum/s2/Slider";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useEffect, useRef, useState } from "react";
import { VIDEO_LABELS } from "./generated/controls.js";
import { VIDEO_ENCODINGS } from "./video-color.js";
export function videoTimeLabel(time) {
  const seconds = Math.max(0, time || 0);
  return `${Math.floor(seconds / 60)}:${(seconds % 60).toFixed(2).padStart(5, "0")}`;
}
export default function VideoControls({
  clip,
  time,
  onTime,
  settings,
  onChange,
  disabled,
}) {
  const player = useRef(null),
    [playing, setPlaying] = useState(false),
    [playError, setPlayError] = useState(null);
  const end = Math.min(settings.trimEnd ?? clip.duration, clip.duration),
    start = Math.max(clip.start, settings.trimStart);
  useEffect(() => {
    const video = player.current;
    if (disabled) video.pause();
  }, [disabled]);
  useEffect(() => {
    player.current.muted = !settings.audio;
  }, [settings.audio]);
  useEffect(() => {
    const video = player.current;
    if (video.currentTime < start || video.currentTime >= end) {
      video.currentTime = start;
      onTime(start);
    }
  }, [start, end]);
  function seek(value) {
    const next = Math.min(
      clip.duration - 0.000001,
      Math.max(clip.start, value),
    );
    player.current.currentTime = next;
    onTime(next);
  }
  return (
    <div className="video-controls" aria-label="Video controls">
      <video
        ref={player}
        hidden
        src={clip.playbackUrl}
        preload="metadata"
        playsInline
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onTimeUpdate={(event) => {
          const video = event.currentTarget;
          if (video.currentTime >= end) {
            video.pause();
            video.currentTime = Math.max(start, end - 0.001);
          }
          onTime(video.currentTime);
        }}
      />
      <div className="video-timeline">
        <ActionButton
          isDisabled={disabled}
          onPress={async () => {
            const video = player.current;
            if (playing) video.pause();
            else {
              if (video.currentTime >= end - 0.01) seek(start);
              try {
                await video.play();
                setPlayError(null);
              } catch {
                setPlayError(
                  "Playback is unavailable for this codec. You can still seek, edit and export decoded frames.",
                );
              }
            }
          }}
          size={"S"}
        >
          {playing ? VIDEO_LABELS.pause : VIDEO_LABELS.play}
        </ActionButton>
        <Slider
          aria-label={VIDEO_LABELS.position}
          minValue={clip.start}
          maxValue={clip.duration}
          step={0.001}
          value={time}
          isDisabled={disabled}
          onChange={(e) => seek(Number(e))}
          size={"S"}
        />
        <output>
          {videoTimeLabel(time)} / {videoTimeLabel(clip.duration)}
        </output>
      </div>
      <div className="video-settings">
        <div>
          {VIDEO_LABELS.encoding}
          <Picker
            aria-label={VIDEO_LABELS.encoding}
            value={settings.encoding}
            isDisabled={disabled}
            onChange={(e) =>
              onChange({
                ...settings,
                encoding: e,
              })
            }
            size={"S"}
          >
            {VIDEO_ENCODINGS.map((item) => (
              <PickerItem key={item.id} id={item.id}>
                {item.label}
              </PickerItem>
            ))}
          </Picker>
        </div>
        <div>
          {VIDEO_LABELS.trimStart}
          <NumberField
            aria-label={VIDEO_LABELS.trimStart}
            minValue={clip.start}
            maxValue={end - 0.001}
            step={0.001}
            value={start}
            isDisabled={disabled}
            onChange={(e) => {
              const value = Number(e);
              if (Number.isFinite(value) && value >= clip.start && value < end)
                onChange({
                  ...settings,
                  trimStart: value,
                });
            }}
            size={"S"}
          />
        </div>
        <div>
          {VIDEO_LABELS.trimEnd}
          <NumberField
            aria-label={VIDEO_LABELS.trimEnd}
            minValue={start + 0.001}
            maxValue={clip.duration}
            step={0.001}
            value={settings.trimEnd ?? clip.duration}
            isDisabled={disabled}
            onChange={(e) => {
              const value = Number(e);
              if (
                Number.isFinite(value) &&
                value > start &&
                value <= clip.duration
              )
                onChange({
                  ...settings,
                  trimEnd: value,
                });
            }}
            size={"S"}
          />
        </div>
        <Switch
          isSelected={settings.audio}
          isDisabled={disabled}
          onChange={(e) =>
            onChange({
              ...settings,
              audio: e,
            })
          }
          size={"S"}
          UNSAFE_className={"video-audio"}
        >
          {VIDEO_LABELS.audio}
        </Switch>
      </div>
      {playError && <p role="status">{playError}</p>}
      <small>
        Preview may skip frames while processing. Export renders every frame in
        the selected range.
      </small>
    </div>
  );
}
