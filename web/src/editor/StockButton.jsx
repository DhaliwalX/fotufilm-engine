import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Icon } from "../icons.jsx";

export default function StockButton({
  name,
  kind,
  url,
  selected,
  onSelect,
  normal = false,
}) {
  return (
    <ToggleButton
      isQuiet
      UNSAFE_className={`stock-row ${normal ? "normal-row" : ""} ${selected ? "selected" : ""}`}
      onPress={onSelect}
      aria-label={`${name} ${kind}`}
      size="S"
      isSelected={selected}
    >
      <span className="stock-thumb">
        {url ? <img key={url} src={url} alt="" /> : <Icon name="film" />}
      </span>
      <span className="stock-copy">
        <span>{name}</span>
        <small>{kind}</small>
      </span>
    </ToggleButton>
  );
}
