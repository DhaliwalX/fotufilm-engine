import { Fragment, useEffect, useState } from "react";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Menu, MenuItem, MenuTrigger } from "@react-spectrum/s2/Menu";
import { ProgressCircle } from "@react-spectrum/s2/ProgressCircle";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";
import { ALL_FOLDERS, folderTree } from "./library-model.js";

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

const nodeId = (folderId, path) => `${folderId}/${path}`;

function Disclosure({ name, expanded, onToggle }) {
  return (
    <button
      type="button"
      className="library-disclosure"
      aria-label={`${expanded ? "Hide" : "Show"} subfolders of ${name}`}
      aria-expanded={expanded}
      onClick={onToggle}
    >
      <Icon name="chevronRight" size={16} />
    </button>
  );
}

// A folder's open subfolders, depth first, as flat rows so the list lays out
// the same as a sidebar and as the narrow layout's strip.
function SubfolderRows({
  folder,
  node,
  depth,
  scope,
  expanded,
  onToggle,
  onSelect,
}) {
  return node.children.map((child) => {
    const id = nodeId(folder.id, child.path),
      open = expanded.has(id);
    return (
      <Fragment key={id}>
        <li
          className="library-folder-row library-subfolder"
          style={{ "--depth": depth }}
        >
          {child.children.length > 0 && (
            <Disclosure
              name={child.name}
              expanded={open}
              onToggle={() => onToggle(id)}
            />
          )}
          <button
            type="button"
            className="library-folder"
            aria-current={
              (scope.folderId === folder.id && scope.path === child.path) ||
              undefined
            }
            title={`${folder.name}/${child.path}`}
            onClick={() => onSelect(folder.id, child.path)}
          >
            <Icon name="folder" size={18} />
            <span className="library-folder-name">{child.name}</span>
            <span className="library-folder-count">
              {count.format(child.count)}
            </span>
          </button>
        </li>
        {open && (
          <SubfolderRows
            folder={folder}
            node={child}
            depth={depth + 1}
            scope={scope}
            expanded={expanded}
            onToggle={onToggle}
            onSelect={onSelect}
          />
        )}
      </Fragment>
    );
  });
}

// `scope` is {folderId, path}: all photos, a folder, or one of its subfolders.
export default function LibraryFolders({
  folders,
  scope,
  total,
  onSelect,
  onAdd,
  onRescan,
  onRemove,
}) {
  const [expanded, setExpanded] = useState(() => new Set());
  const toggle = (id) =>
    setExpanded((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  // The chosen folder opens to show what is inside it.
  const current = nodeId(scope.folderId, scope.path);
  useEffect(
    () =>
      setExpanded((list) =>
        list.has(current) ? list : new Set(list).add(current),
      ),
    [current],
  );
  const trees = folders.map((folder) => folderTree(folder.photos));
  const nested = trees.some((tree) => tree.get("").children.length > 0);

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
      <ul className={`library-folder-list${nested ? " nested" : ""}`}>
        <li>
          <button
            type="button"
            className="library-folder"
            aria-current={scope.folderId === ALL_FOLDERS || undefined}
            onClick={() => onSelect(ALL_FOLDERS, "")}
          >
            <Icon name="library" size={18} />
            <span className="library-folder-name">All Photos</span>
            <span className="library-folder-count">{count.format(total)}</span>
          </button>
        </li>
        {folders.map((folder, index) => {
          // A saved folder asks again after a browser restart; asking
          // needs a click.
          const asking = folder.status === "permission",
            root = trees[index].get(""),
            id = nodeId(folder.id, ""),
            open = expanded.has(id);
          return (
            <Fragment key={folder.id}>
              <li className="library-folder-row">
                {root.children.length > 0 && (
                  <Disclosure
                    name={folder.name}
                    expanded={open}
                    onToggle={() => toggle(id)}
                  />
                )}
                <button
                  type="button"
                  className={`library-folder${asking ? " asking" : ""}`}
                  aria-current={
                    (scope.folderId === folder.id && !scope.path) || undefined
                  }
                  title={
                    folder.transient
                      ? `${folder.name} · this session only`
                      : folder.name
                  }
                  onClick={() => onSelect(folder.id, "")}
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
                        action === "rescan"
                          ? onRescan(folder)
                          : onRemove(folder)
                      }
                    >
                      {folder.handle && <MenuItem id="rescan">Rescan</MenuItem>}
                      <MenuItem id="remove">Remove from Library…</MenuItem>
                    </Menu>
                  </MenuTrigger>
                </span>
              </li>
              {open && (
                <SubfolderRows
                  folder={folder}
                  node={root}
                  depth={1}
                  scope={scope}
                  expanded={expanded}
                  onToggle={toggle}
                  onSelect={onSelect}
                />
              )}
            </Fragment>
          );
        })}
      </ul>
    </nav>
  );
}
