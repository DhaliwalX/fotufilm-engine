import { useEffect, useRef, useState } from 'react'
import { VIDEO_LABELS } from './generated/controls.js'
import { VIDEO_ENCODINGS } from './video-color.js'

export function videoTimeLabel(time) {
  const seconds = Math.max(0, time || 0)
  return `${Math.floor(seconds / 60)}:${(seconds % 60).toFixed(2).padStart(5, '0')}`
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
    [playError, setPlayError] = useState(null)
  const end = Math.min(settings.trimEnd ?? clip.duration, clip.duration),
    start = Math.max(clip.start, settings.trimStart)
  useEffect(() => {
    const video = player.current
    if (disabled) video.pause()
  }, [disabled])
  useEffect(() => {
    player.current.muted = !settings.audio
  }, [settings.audio])
  useEffect(() => {
    const video = player.current
    if (video.currentTime < start || video.currentTime >= end) {
      video.currentTime = start
      onTime(start)
    }
  }, [start, end])
  function seek(value) {
    const next = Math.min(clip.duration - 0.000001, Math.max(clip.start, value))
    player.current.currentTime = next
    onTime(next)
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
          const video = event.currentTarget
          if (video.currentTime >= end) {
            video.pause()
            video.currentTime = Math.max(start, end - 0.001)
          }
          onTime(video.currentTime)
        }}
      />
      <div className="video-timeline">
        <button
          disabled={disabled}
          onClick={async () => {
            const video = player.current
            if (playing) video.pause()
            else {
              if (video.currentTime >= end - 0.01) seek(start)
              try {
                await video.play()
                setPlayError(null)
              } catch {
                setPlayError(
                  'Playback is unavailable for this codec. You can still seek, edit and export decoded frames.',
                )
              }
            }
          }}
        >
          {playing ? VIDEO_LABELS.pause : VIDEO_LABELS.play}
        </button>
        <input
          type="range"
          aria-label={VIDEO_LABELS.position}
          min={clip.start}
          max={clip.duration}
          step="0.001"
          value={time}
          disabled={disabled}
          onChange={(e) => seek(Number(e.target.value))}
        />
        <output>
          {videoTimeLabel(time)} / {videoTimeLabel(clip.duration)}
        </output>
      </div>
      <div className="video-settings">
        <label>
          {VIDEO_LABELS.encoding}
          <select
            aria-label={VIDEO_LABELS.encoding}
            value={settings.encoding}
            disabled={disabled}
            onChange={(e) =>
              onChange({ ...settings, encoding: e.target.value })
            }
          >
            {VIDEO_ENCODINGS.map((item) => (
              <option key={item.id} value={item.id}>
                {item.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          {VIDEO_LABELS.trimStart}
          <input
            aria-label={VIDEO_LABELS.trimStart}
            type="number"
            min={clip.start}
            max={end - 0.001}
            step="0.001"
            value={start}
            disabled={disabled}
            onChange={(e) => {
              const value = Number(e.target.value)
              if (Number.isFinite(value) && value >= clip.start && value < end)
                onChange({ ...settings, trimStart: value })
            }}
          />
        </label>
        <label>
          {VIDEO_LABELS.trimEnd}
          <input
            aria-label={VIDEO_LABELS.trimEnd}
            type="number"
            min={start + 0.001}
            max={clip.duration}
            step="0.001"
            value={settings.trimEnd ?? clip.duration}
            disabled={disabled}
            onChange={(e) => {
              const value = Number(e.target.value)
              if (
                Number.isFinite(value) &&
                value > start &&
                value <= clip.duration
              )
                onChange({ ...settings, trimEnd: value })
            }}
          />
        </label>
        <label className="video-audio">
          <input
            type="checkbox"
            checked={settings.audio}
            disabled={disabled}
            onChange={(e) => onChange({ ...settings, audio: e.target.checked })}
          />
          {VIDEO_LABELS.audio}
        </label>
      </div>
      {playError && <p role="status">{playError}</p>}
      <small>
        Preview may skip frames while processing. Export renders every frame in
        the selected range.
      </small>
    </div>
  )
}
