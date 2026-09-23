import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";

export default function PlayerButton({
  label,
  icon,
  selected,
  shortcut,
  ...props
}) {
  const Button = selected === undefined ? ActionButton : ToggleButton;
  return (
    <TooltipTrigger>
      <Button
        aria-label={label}
        aria-keyshortcuts={shortcut}
        isQuiet
        size="M"
        {...(selected === undefined ? {} : { isSelected: selected })}
        {...props}
      >
        <span className="player-icon" key={icon}>
          <Icon name={icon} size={22} />
        </span>
      </Button>
      <Tooltip>
        {label}
        {shortcut ? ` · ${shortcut}` : ""}
      </Tooltip>
    </TooltipTrigger>
  );
}
