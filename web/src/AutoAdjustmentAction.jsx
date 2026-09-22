import { Text } from "@react-spectrum/s2/Text";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { Icon } from "./icons.jsx";
import { editorControl } from "./editor-catalogue.js";
export default function AutoAdjustmentAction({ auto, onClick }) {
  const control = editorControl("autoAdjustment");
  return (
    <ToggleButton
      title={`${control.detail} (⌘⇧A)`}
      size="S"
      isDisabled={!auto.available}
      onPress={onClick}
      isSelected={auto.active}
      isQuiet
    >
      {auto.active && !auto.busy ? <Icon name="check" /> : undefined}
      <Text>{auto.busy ? "Cancel Auto Adjust" : control.title}</Text>
    </ToggleButton>
  );
}
