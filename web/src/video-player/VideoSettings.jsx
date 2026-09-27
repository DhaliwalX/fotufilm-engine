import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { DialogTrigger, Popover } from "@react-spectrum/s2/Popover";
import { NumberField } from "@react-spectrum/s2/NumberField";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { Switch } from "@react-spectrum/s2/Switch";
import { VIDEO_LABELS as labels } from "../generated/controls.js";
import { VIDEO_ENCODINGS } from "../video-color.js";
import { Icon } from "../icons.jsx";

// The Mac app's Cadence choices; Native keeps the source's rate.
const CADENCES = [
  ["native", "cadenceNative"],
  ["16", "cadence16"],
  ["18", "cadence18"],
  ["24", "cadence24"],
];

export default function VideoSettings({
  clip,
  start,
  end,
  position,
  settings,
  onChange,
  disabled,
  cadence,
}) {
  const patch = (change) => onChange({ ...settings, ...change });
  const setStart = (value) => {
    if (Number.isFinite(value) && value >= clip.start && value < end)
      patch({ trimStart: value });
  };
  const setEnd = (value) => {
    if (Number.isFinite(value) && value > start && value <= clip.duration)
      patch({ trimEnd: value });
  };
  return (
    <DialogTrigger>
      <ActionButton
        aria-label={labels.settings}
        isQuiet
        size="M"
        isDisabled={disabled}
      >
        <Icon name="adjustments" size={22} />
      </ActionButton>
      <Popover aria-label={labels.settings} placement="top end" hideArrow>
        <div className="video-settings">
          <h3>{labels.settings}</h3>
          <Picker
            label={labels.encoding}
            value={settings.encoding}
            isDisabled={disabled}
            onChange={(encoding) => patch({ encoding })}
            size="S"
            UNSAFE_style={{ width: "100%" }}
          >
            {VIDEO_ENCODINGS.map((item) => (
              <PickerItem key={item.id} id={item.id}>
                {item.label}
              </PickerItem>
            ))}
          </Picker>
          <div className="video-trim-fields">
            <NumberField
              label={labels.trimStart}
              minValue={clip.start}
              maxValue={end - 0.001}
              step={0.001}
              value={start}
              onChange={setStart}
              isDisabled={disabled}
              size="S"
              formatOptions={{ maximumFractionDigits: 3 }}
              UNSAFE_style={{ width: "100%", minWidth: 0 }}
            />
            <NumberField
              label={labels.trimEnd}
              minValue={start + 0.001}
              maxValue={clip.duration}
              step={0.001}
              value={end}
              onChange={setEnd}
              isDisabled={disabled}
              size="S"
              formatOptions={{ maximumFractionDigits: 3 }}
              UNSAFE_style={{ width: "100%", minWidth: 0 }}
            />
            <ActionButton
              size="S"
              isQuiet
              onPress={() => setStart(position)}
              isDisabled={disabled || position >= end}
            >
              {labels.setIn}
            </ActionButton>
            <ActionButton
              size="S"
              isQuiet
              onPress={() => setEnd(position)}
              isDisabled={disabled || position <= start}
            >
              {labels.setOut}
            </ActionButton>
          </div>
          <ActionButton
            size="S"
            isQuiet
            onPress={() => patch({ trimStart: clip.start, trimEnd: null })}
            isDisabled={
              disabled || (start === clip.start && end === clip.duration)
            }
          >
            {labels.resetTrim}
          </ActionButton>
          {cadence && (
            <>
              <Picker
                label={labels.cadence}
                value={String(settings.frameRate ?? "native")}
                isDisabled={disabled}
                onChange={(id) =>
                  patch({ frameRate: id === "native" ? null : Number(id) })
                }
                size="S"
                UNSAFE_style={{ width: "100%" }}
              >
                {CADENCES.map(([id, label]) => (
                  <PickerItem key={id} id={id}>
                    {labels[label]}
                  </PickerItem>
                ))}
              </Picker>
              <p className="video-settings-note">{labels.cadenceNote}</p>
            </>
          )}
          <Switch
            isSelected={settings.audio}
            isDisabled={disabled}
            onChange={(audio) => patch({ audio })}
            size="S"
          >
            {labels.audio}
          </Switch>
        </div>
      </Popover>
    </DialogTrigger>
  );
}
