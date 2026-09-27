import { Dialog, Heading, Content } from "@react-spectrum/s2/Dialog";
import { editorControl } from "../editor-catalogue.js";
import { shortcutLabel } from "../shortcut-label.js";
export default function ShortcutsDialog() {
  return (
    <Dialog aria-label="Keyboard shortcuts" isDismissible size={"M"}>
      <Heading>{"Keyboard shortcuts"}</Heading>
      <Content>
        <dl className="shortcuts">
          {[
            ["Open images", shortcutLabel("⌘O")],
            ["Export", shortcutLabel("⌘S")],
            ["Undo", shortcutLabel("⌘Z")],
            ["Redo", shortcutLabel("⇧⌘Z")],
            [editorControl("autoAdjustment").title, shortcutLabel("⇧⌘A")],
            ["Compare photo", "Hold Space"],
            ["Show negative", shortcutLabel("⌥⌘N")],
            ["Video play / pause", "Space / K in viewer"],
            ["Video seek", "← / → or J / L in viewer"],
            ["Mute video preview", "M in viewer"],
            ["Histogram", "H"],
            ["Crop", "C"],
            ["Apply crop", "Return"],
            ["Zoom", "+ / −"],
            ["Fit", "0"],
            ["Reset adjustment", "Double-click slider"],
          ].map(([action, keys]) => (
            <div key={action}>
              <dt>{action}</dt>
              <dd>{keys}</dd>
            </div>
          ))}
        </dl>
      </Content>
    </Dialog>
  );
}
