import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Menu, MenuItem, MenuTrigger } from "@react-spectrum/s2/Menu";
import { VIDEO_LABELS as labels } from "../generated/controls.js";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import PlayerButton from "./PlayerButton.jsx";
import { setAppSetting, useAppSetting } from "../app-settings.js";
import {
  PLAYBACK_QUALITIES,
  PLAYBACK_QUALITY_HELP,
} from "./playback-quality.js";

const qualityLabel = (id) =>
  (PLAYBACK_QUALITIES.find((quality) => quality.id === id) ?? PLAYBACK_QUALITIES[2]).label;

export default function VideoTransport({ playback, disabled, quality = false, children }) {
  const { playing, loop, setLoop, muted, setMuted, rate, setRate, transport } =
    playback;
  const playbackQuality = useAppSetting("videoPlaybackQuality");
  return (
    <div className="video-transport">
      <div className="video-transport-group">
        <PlayerButton
          icon="replay5"
          label={labels.back}
          onPress={() => transport.current?.skip(-5)}
          isDisabled={disabled}
        />
        <PlayerButton
          icon={playing ? "pause" : "play"}
          label={playing ? labels.pause : labels.play}
          UNSAFE_className="video-play-button"
          size="L"
          isQuiet={false}
          onPress={() => transport.current?.toggle()}
          isDisabled={disabled}
        />
        <PlayerButton
          icon="forward5"
          label={labels.forward}
          onPress={() => transport.current?.skip(5)}
          isDisabled={disabled}
        />
      </div>
      <div className="video-transport-group video-transport-options">
        <PlayerButton
          icon="loop"
          label={labels.loop}
          selected={loop}
          onPress={() => setLoop(!loop)}
          isDisabled={disabled}
        />
        <PlayerButton
          icon={muted ? "muted" : "volume"}
          label={muted ? labels.unmute : labels.mute}
          selected={muted}
          onPress={() => setMuted(!muted)}
          isDisabled={disabled}
        />
        <MenuTrigger>
          <ActionButton
            aria-label={`${labels.speed}: ${rate}×`}
            isQuiet
            size="M"
            isDisabled={disabled}
          >
            <span className="video-speed">{rate}×</span>
          </ActionButton>
          <Menu
            aria-label={labels.speed}
            selectionMode="single"
            selectedKeys={[String(rate)]}
            onAction={(key) => setRate(Number(key))}
          >
            {[0.25, 0.5, 1, 1.5, 2].map((speed) => (
              <MenuItem key={speed} id={String(speed)}>
                {speed}×
              </MenuItem>
            ))}
          </Menu>
        </MenuTrigger>
        {quality && (
          <MenuTrigger>
            <TooltipTrigger>
              <ActionButton
                aria-label={`Playback quality: ${qualityLabel(playbackQuality)}`}
                isQuiet
                size="M"
                isDisabled={disabled}
              >
                <span className="video-speed">{qualityLabel(playbackQuality)}</span>
              </ActionButton>
              <Tooltip>{PLAYBACK_QUALITY_HELP}</Tooltip>
            </TooltipTrigger>
            <Menu
              aria-label="Playback quality"
              selectionMode="single"
              selectedKeys={[playbackQuality]}
              onAction={(key) => setAppSetting("videoPlaybackQuality", String(key))}
            >
              {PLAYBACK_QUALITIES.map(({ id, label }) => (
                <MenuItem key={id} id={id}>
                  {label}
                </MenuItem>
              ))}
            </Menu>
          </MenuTrigger>
        )}
        {children}
      </div>
    </div>
  );
}
