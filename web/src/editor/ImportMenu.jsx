import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Menu, MenuItem, MenuTrigger } from "@react-spectrum/s2/Menu";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";

export default function ImportMenu() {
  const { exporting, openFiles, importNegatives, importTrichromatic } = useEditor();
  return (
    <MenuTrigger>
      <ActionButton
        aria-label="Add media"
        size="S"
        isQuiet
        isDisabled={exporting}
      >
        <Icon name="plus" />
      </ActionButton>
      <Menu
        aria-label="Add media"
        onAction={(kind) =>
          kind === "negative"
            ? importNegatives()
            : kind === "trichromatic"
              ? importTrichromatic()
              : openFiles(kind)
        }
      >
        <MenuItem id="image">Image</MenuItem>
        <MenuItem id="video">Video</MenuItem>
        {importNegatives && <MenuItem id="negative">Negative</MenuItem>}
        {importTrichromatic && <MenuItem id="trichromatic">Trichromatic Negative</MenuItem>}
      </Menu>
    </MenuTrigger>
  );
}
