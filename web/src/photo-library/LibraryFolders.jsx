import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Menu, MenuItem, MenuTrigger } from "@react-spectrum/s2/Menu";
import { ProgressCircle } from "@react-spectrum/s2/ProgressCircle";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";
import { ALL_FOLDERS } from "./library-model.js";

const count = new Intl.NumberFormat();

function FolderStatus({ folder }) {
  if (folder.status === "permission") return null;
  if (folder.status === "error")
    return (
      <span className="library-folder-error" title={folder.error}>
        <Icon name="warning" size={14} />
      </span>
    );
  return (
    <span className="library-folder-count">
      {folder.status === "scanning" && (
        <ProgressCircle
          aria-label={`Reading ${folder.name}`}
          isIndeterminate
          size="S"
        />
      )}
      {count.format(folder.photos.length)}
    </span>
  );
}

export default function LibraryFolders({
  folders,
  folderId,
  total,
  onSelect,
  onAdd,
  onRescan,
  onRemove,
}) {
  return (
    <nav className="library-folders" aria-label="Folders">
      <div className="library-folders-heading">
        <span>Library</span>
        <TooltipTrigger>
          <ActionButton
            aria-label="Add Folder"
            size="S"
            isQuiet
            onPress={onAdd}
          >
            <Icon name="addFolder" />
          </ActionButton>
          <Tooltip>Add Folder</Tooltip>
        </TooltipTrigger>
      </div>
      <ul className="library-folder-list">
        <li>
          <button
            type="button"
            className="library-folder"
            aria-current={folderId === ALL_FOLDERS || undefined}
            onClick={() => onSelect(ALL_FOLDERS)}
          >
            <Icon name="library" size={18} />
            <span className="library-folder-name">All Photos</span>
            <span className="library-folder-count">{count.format(total)}</span>
          </button>
        </li>
        {folders.map((folder) => {
          // A saved folder asks again after a browser restart; asking
          // needs a click.
          const asking = folder.status === "permission";
          return (
            <li key={folder.id} className="library-folder-row">
              <button
                type="button"
                className={`library-folder${asking ? " asking" : ""}`}
                aria-current={folderId === folder.id || undefined}
                title={
                  folder.transient
                    ? `${folder.name} · this session only`
                    : folder.name
                }
                onClick={() => onSelect(folder.id)}
              >
                <Icon name="folder" size={18} />
                <span className="library-folder-name">{folder.name}</span>
                <FolderStatus folder={folder} />
              </button>
              <span
                className={`library-folder-actions${asking ? " asking" : ""}`}
              >
                {asking && (
                  <ActionButton size="XS" onPress={() => onRescan(folder)}>
                    Allow
                  </ActionButton>
                )}
                <MenuTrigger>
                  <ActionButton
                    aria-label={`${folder.name} options`}
                    size="XS"
                    isQuiet
                  >
                    <Icon name="more" size={16} />
                  </ActionButton>
                  <Menu
                    onAction={(action) =>
                      action === "rescan" ? onRescan(folder) : onRemove(folder)
                    }
                  >
                    {folder.handle && <MenuItem id="rescan">Rescan</MenuItem>}
                    <MenuItem id="remove">Remove from Library…</MenuItem>
                  </Menu>
                </MenuTrigger>
              </span>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
