import { ActionButton } from "@react-spectrum/s2/ActionButton";
import {
  Menu,
  MenuItem,
  MenuSection,
  MenuTrigger,
} from "@react-spectrum/s2/Menu";

// What a photo's context menu acts on: the selection when the photo is in it,
// else the photo alone, as Finder does.
export function menuTargets(photos, selected, key) {
  if (selected.has(key))
    return photos.filter((photo) => selected.has(photo.key));
  return photos.filter((photo) => photo.key === key);
}

// The library's context menu, opened at the pointer over a tile (`menu` {key,
// x, y}); `targets` are what it acts on. Showing, renaming and trashing need a
// host that reads the folders (`actions`, the words for each); renaming takes
// one photo.
export default function PhotoMenu({
  menu,
  targets,
  actions,
  selected,
  onAction,
  onClose,
}) {
  if (!menu) return null;
  const single = targets.length === 1;
  return (
    <MenuTrigger isOpen onOpenChange={(open) => !open && onClose()}>
      <ActionButton
        aria-label="Photo actions"
        UNSAFE_className="library-menu-anchor"
        UNSAFE_style={{ left: menu.x, top: menu.y }}
      />
      <Menu
        aria-label="Photo actions"
        onAction={(action) => {
          onClose();
          onAction(action);
        }}
      >
        <MenuSection>
          <MenuItem id="open">
            {single ? "Open" : `Open ${targets.length} Photos`}
          </MenuItem>
          {actions?.reveal && <MenuItem id="reveal">{actions.reveal}</MenuItem>}
        </MenuSection>
        <MenuSection>
          <MenuItem id="select">
            {selected.has(menu.key) ? "Deselect" : "Select"}
          </MenuItem>
        </MenuSection>
        {actions && (
          <MenuSection>
            {single && <MenuItem id="rename">Rename…</MenuItem>}
            {actions.trash && (
              <MenuItem id="trash">{`${actions.trash}…`}</MenuItem>
            )}
          </MenuSection>
        )}
      </Menu>
    </MenuTrigger>
  );
}
