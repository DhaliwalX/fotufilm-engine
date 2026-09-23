import { useRef } from "react";
import Presence from "./Presence.jsx";
import VideoTimeline from "./video-player/VideoTimeline.jsx";
import VideoTransport from "./video-player/VideoTransport.jsx";
import VideoSettings from "./video-player/VideoSettings.jsx";
import { useVideoPlayback } from "./video-player/useVideoPlayback.js";
import { usePlayerShortcuts } from "./video-player/usePlayerShortcuts.js";
export { videoTimeLabel } from "./video-player/time.js";

export default function VideoControls({
  clip,
  time,
  onTime,
  settings,
  onChange,
  disabled,
}) {
  const root = useRef(null);
  const start = Math.max(clip.start, settings.trimStart);
  const end = Math.min(settings.trimEnd ?? clip.duration, clip.duration);
  const playback = useVideoPlayback({ start, end, time, onTime, disabled });
  usePlayerShortcuts(root, playback, disabled);
  return (
    <section
      ref={root}
      className="video-controls"
      aria-label="Video controls"
      tabIndex={0}
    >
      <video
        ref={playback.player}
        hidden
        src={clip.playbackUrl}
        preload="metadata"
        playsInline
      />
      <VideoTimeline
        clip={clip}
        start={start}
        end={end}
        position={playback.position}
        seek={(value) => playback.transport.current?.seek(value)}
        disabled={disabled}
      />
      <VideoTransport playback={playback} disabled={disabled}>
        <VideoSettings
          clip={clip}
          start={start}
          end={end}
          position={playback.position}
          settings={settings}
          onChange={onChange}
          disabled={disabled}
        />
      </VideoTransport>
      <Presence
        show={!!playback.error}
        className="video-playback-error"
        role="status"
        initial={{ opacity: 0, height: 0 }}
        animate={{ opacity: 1, height: "auto" }}
        exit={{ opacity: 0, height: 0 }}
      >
        {playback.error}
      </Presence>
    </section>
  );
}
