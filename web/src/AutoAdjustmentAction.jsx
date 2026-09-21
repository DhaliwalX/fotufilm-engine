import { Button } from "@astryxdesign/core/Button";
import { Icon } from "./icons.jsx";
import { editorControl } from "./editor-catalogue.js";

export default function AutoAdjustmentAction({ auto, onClick }) {
  const control = editorControl("autoAdjustment");
  return (
    <Button
      label={auto.busy ? "Cancel Auto Adjust" : control.title}
      title={`${control.detail} (⌘⇧A)`}
      aria-pressed={auto.active}
      variant={auto.active ? "secondary" : "ghost"}
      size="sm"
      icon={auto.active && !auto.busy ? <Icon name="check" /> : undefined}
      isDisabled={!auto.available}
      onClick={onClick}
    />
  );
}
