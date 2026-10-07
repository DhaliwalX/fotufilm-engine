import {
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { motion } from "motion/react";
import { AlertDialog } from "@react-spectrum/s2/AlertDialog";
import { Button } from "@react-spectrum/s2/Button";
import { DialogContainer } from "@react-spectrum/s2/Dialog";
import { Icon } from "../icons.jsx";
import LibraryBar from "./LibraryBar.jsx";
import LibraryFolders from "./LibraryFolders.jsx";
import PhotoGrid, { tileId } from "./PhotoGrid.jsx";
import PhotoMenu, { menuTargets } from "./PhotoMenu.jsx";
import RenameDialog from "./RenameDialog.jsx";
import { currentFile } from "./library-scan.js";
import {
  ALL_FOLDERS,
  filteredPhotos,
  folderTree,
  nextSelection,
  rollEdit,
  sortedPhotos,
  steppedKey,
} from "./library-model.js";
import { createThumbnails } from "./thumbnails.js";
import { supportsFolderAccess, usePhotoLibrary } from "./usePhotoLibrary.js";
import "./photo-library.css";

const EASE = [0.2, 0.8, 0.2, 1];
const TILE_SIZE_KEY = "fotufilm.library.tileSize";
const noFilters = { search: "", sort: "name", minRating: 0, editedOnly: false };
const allPhotos = { folderId: ALL_FOLDERS, path: "" };

// The same array while its items are the same, so a folder's status changing
// does not re-sort its photos.
function useSameItems(list) {
  const kept = useRef(list);
  if (
    list.length !== kept.current.length ||
    list.some((item, index) => item !== kept.current[index])
  )
    kept.current = list;
  return kept.current;
}

function EmptyState({ folders, filtered, onAdd, onClear }) {
  if (filtered)
    return (
      <div className="library-empty">
        <p>No photos match.</p>
        <Button size="S" variant="secondary" onPress={onClear}>
          Clear Filters
        </Button>
      </div>
    );
  if (folders.length)
    return (
      <div className="library-empty">
        <p>No photos in this folder.</p>
      </div>
    );
  return (
    <div className="library-empty">
      <Icon name="library" size={36} />
      <p>Add a folder to browse, rate and open its photos.</p>
      <Button size="S" variant="accent" onPress={onAdd}>
        Add Folder
      </Button>
      {!supportsFolderAccess() && (
        <small>
          This browser can’t keep access to folders, so they last for this
          session.
        </small>
      )}
    </div>
  );
}

// The library view. `onOpenPhotos({items, origin})` receives
// {key, name, file} per photo, the key its edit is kept under
// (loadLibraryEdit/saveLibraryEdit), and the first tile's on-screen rectangle
// and thumbnail. A photo renamed here is reported to `onPhotoRenamed({from,
// to, name})`, its old and new keys; photos moved to the trash to
// `onPhotosTrashed(keys)`.
export default function PhotoLibrary({
  open,
  onOpenPhotos,
  onPhotoRenamed,
  onPhotosTrashed,
  onClose,
  negatives = false,
  renderThumbnail = null,
}) {
  const library = usePhotoLibrary(open);
  const [thumbnails, setThumbnails] = useState(null);
  const [scope, setScope] = useState(allPhotos);
  const [filters, setFilters] = useState(noFilters);
  const [tileSize, setTileSize] = useState(
    () => Number(localStorage.getItem(TILE_SIZE_KEY)) || 168,
  );
  const [selection, setSelection] = useState({
    selected: new Set(),
    anchor: null,
  });
  const [focusKey, setFocusKey] = useState(null);
  const [removing, setRemoving] = useState(null);
  const [menu, setMenu] = useState(null),
    [renaming, setRenaming] = useState(null),
    [trashing, setTrashing] = useState(null);
  const upload = useRef(null),
    grid = useRef(null);

  // Edited photos and negatives are drawn by the editor (`renderThumbnail`), which may change.
  const render = useRef(renderThumbnail);
  render.current = renderThumbnail;
  useEffect(() => {
    const cache = createThumbnails({
      render: (photo) => render.current?.(photo) ?? Promise.resolve(null),
    });
    setThumbnails(cache);
    return () => cache.dispose();
  }, []);
  useEffect(
    () => localStorage.setItem(TILE_SIZE_KEY, String(tileSize)),
    [tileSize],
  );
  useEffect(() => {
    if (open)
      requestAnimationFrame(() =>
        grid.current?.querySelector(".library-grid")?.focus(),
      );
  }, [open]);

  // A folder or subfolder that disappears, removed or emptied on a rescan,
  // leaves its parent in view.
  const folder = library.folders.find((item) => item.id === scope.folderId);
  const subfolder = folder && folderTree(folder.photos).get(scope.path);
  if (scope.folderId !== ALL_FOLDERS && !folder) setScope(allPhotos);
  else if (folder && !subfolder) setScope({ folderId: folder.id, path: "" });
  const scopeFolders = folder ? [folder] : library.folders;

  const search = useDeferredValue(filters.search);
  const lists = useSameItems(scopeFolders.map((item) => item.photos));
  const sortRecords = filters.sort === "rating" ? library.records : null;
  const sorted = useMemo(
    () => sortedPhotos(lists, sortRecords, filters.sort),
    [lists, sortRecords, filters.sort],
  );
  const photos = useMemo(
    () =>
      filteredPhotos(sorted, library.records, {
        ...filters,
        search,
        path: scope.path,
      }),
    [sorted, library.records, filters, search, scope.path],
  );
  const total = library.folders.reduce(
    (sum, folder) => sum + folder.photos.length,
    0,
  );
  const selectedPhotos = photos.filter((photo) =>
    selection.selected.has(photo.key),
  );
  const patchFilters = useCallback(
    (patch) => setFilters((current) => ({ ...current, ...patch })),
    [],
  );

  const addFolder = async ({ negative = false } = {}) => {
    if (!supportsFolderAccess()) {
      upload.current.dataset.negative = String(negative);
      return upload.current.click();
    }
    const id = await library.addFolder({ negative });
    if (id) setScope({ folderId: id, path: "" });
  };

  const openPhotos = async (list) => {
    if (!list.length) return;
    const items = [],
      missing = [];
    for (const photo of list) {
      try {
        items.push({
          key: photo.key,
          name: photo.name,
          file: await currentFile(photo),
          ...(photo.negative && negatives
            ? { negative: true, roll: rollEdit(library.records, photo.folderId) }
            : {}),
        });
      } catch {
        missing.push(photo.name);
      }
    }
    const tile = document.getElementById(tileId(photos.indexOf(list[0])));
    const image = tile?.querySelector("img");
    onOpenPhotos({
      items,
      missing,
      origin: image?.complete
        ? { rect: image.getBoundingClientRect(), src: image.currentSrc }
        : null,
    });
  };

  const press = useCallback(
    (key, event) => {
      const range = event.shiftKey,
        toggle = event.metaKey || event.ctrlKey;
      setSelection((current) =>
        !range &&
        !toggle &&
        current.selected.has(key) &&
        current.selected.size > 1
          ? current
          : nextSelection(photos, current, key, { range, toggle }),
      );
      setFocusKey(key);
    },
    [photos],
  );
  const openKey = useCallback(
    (key) => openPhotos(photos.filter((photo) => photo.key === key)),
    [photos, library.records],
  );
  const rate = useCallback(
    (key, rating) =>
      library.rate(
        selection.selected.has(key) ? [...selection.selected] : [key],
        rating,
      ),
    [library.rate, selection],
  );

  const showMenu = useCallback((key, event) => {
    setFocusKey(key);
    setMenu({ key, x: event.clientX, y: event.clientY });
  }, []);
  const menuPhotos = menu
    ? menuTargets(photos, selection.selected, menu.key)
    : [];
  const fileActions = (list) =>
    list.length && list.every((photo) => photo.root?.fileActions)
      ? list[0].root.fileActions
      : null;
  const revealPhotos = (list) => {
    for (const root of new Set(list.map((photo) => photo.root)))
      root
        .reveal(
          list
            .filter((photo) => photo.root === root)
            .map((photo) => photo.path),
        )
        .catch(() => {});
  };
  const menuAction = (action) => {
    if (action === "open") openPhotos(menuPhotos);
    else if (action === "reveal") revealPhotos(menuPhotos);
    else if (action === "select")
      setSelection((current) =>
        nextSelection(photos, current, menu.key, { toggle: true }),
      );
    else if (action === "rename") setRenaming(menuPhotos[0]);
    else if (action === "trash") setTrashing(menuPhotos);
  };
  const rename = async (photo, name) => {
    const renamed = await library.renamePhoto(photo, name);
    if (!renamed) return;
    const swap = (key) => (key === renamed.from ? renamed.to : key);
    setSelection((current) => ({
      selected: new Set([...current.selected].map(swap)),
      anchor: swap(current.anchor),
    }));
    setFocusKey(swap);
    onPhotoRenamed?.(renamed);
  };
  const trash = async (list) => {
    const removed = new Set(await library.trashPhotos(list));
    if (!removed.size) return;
    setSelection((current) => ({
      selected: new Set(
        [...current.selected].filter((key) => !removed.has(key)),
      ),
      anchor: removed.has(current.anchor) ? null : current.anchor,
    }));
    onPhotosTrashed?.([...removed]);
  };

  const keyDown = (event, layout) => {
    const command = event.metaKey || event.ctrlKey;
    const pageRows = Math.max(
      1,
      Math.floor(event.currentTarget.clientHeight / layout.row),
    );
    const steps = {
      ArrowLeft: -1,
      ArrowRight: 1,
      ArrowUp: -layout.columns,
      ArrowDown: layout.columns,
      PageUp: -layout.columns * pageRows,
      PageDown: layout.columns * pageRows,
      Home: -photos.length,
      End: photos.length,
    };
    if (event.key in steps) {
      event.preventDefault();
      const key = steppedKey(photos, focusKey, steps[event.key]);
      if (!key) return;
      setFocusKey(key);
      setSelection((current) =>
        nextSelection(photos, current, key, { range: event.shiftKey }),
      );
    } else if (command && event.key.toLowerCase() === "a") {
      event.preventDefault();
      setSelection({
        selected: new Set(photos.map((photo) => photo.key)),
        anchor: focusKey,
      });
    } else if (event.key === "Enter") {
      event.preventDefault();
      openPhotos(selectedPhotos);
    } else if (
      command &&
      event.key === "Backspace" &&
      fileActions(selectedPhotos)?.trash
    ) {
      event.preventDefault();
      setTrashing(selectedPhotos);
    } else if (event.key === "ContextMenu" && focusKey) {
      // The menu key opens the focused photo's menu beside it.
      event.preventDefault();
      const rect = document
        .getElementById(
          tileId(photos.findIndex((photo) => photo.key === focusKey)),
        )
        ?.getBoundingClientRect();
      if (rect)
        showMenu(focusKey, { clientX: rect.left + 24, clientY: rect.top + 24 });
    } else if (
      !command &&
      /^[0-5]$/.test(event.key) &&
      selection.selected.size
    ) {
      event.preventDefault();
      library.rate([...selection.selected], Number(event.key));
    } else if (!command && event.key.toLowerCase() === "l") {
      onClose();
    } else if (event.key === "Escape") {
      event.stopPropagation();
      if (selection.selected.size)
        setSelection({ selected: new Set(), anchor: null });
      else onClose();
    }
  };

  const filtered =
    filters.search !== "" || filters.minRating > 0 || filters.editedOnly;
  return (
    <motion.section
      ref={grid}
      className="photo-library"
      aria-label="Library"
      aria-hidden={!open}
      inert={!open}
      initial={false}
      animate={
        open
          ? { opacity: 1, visibility: "visible" }
          : { opacity: 0, transitionEnd: { visibility: "hidden" } }
      }
      transition={{ duration: 0.22, ease: EASE }}
    >
      <LibraryFolders
        folders={library.folders}
        scope={scope}
        total={total}
        onSelect={(folderId, path) => {
          setScope({ folderId, path });
          setSelection({ selected: new Set(), anchor: null });
        }}
        onAdd={addFolder}
        onRescan={library.rescan}
        onRemove={setRemoving}
        onMarkNegative={negatives ? library.markNegative : null}
      />
      <motion.div
        className="library-main"
        initial={false}
        animate={open ? { scale: 1, y: 0 } : { scale: 0.992, y: 6 }}
        transition={{ duration: 0.26, ease: EASE }}
      >
        <LibraryBar
          title={subfolder?.name || folder?.name || "All Photos"}
          shown={photos.length}
          selected={selectedPhotos.length}
          filters={filters}
          onFilters={patchFilters}
          tileSize={tileSize}
          onTileSize={setTileSize}
          onOpen={() => openPhotos(selectedPhotos)}
        />
        {library.error && (
          <div className="library-notice" role="alert">
            <span>{library.error}</span>
            <button type="button" onClick={library.dismissError}>
              Dismiss
            </button>
          </div>
        )}
        <PhotoGrid
          photos={photos}
          records={library.records}
          tileSize={tileSize}
          // Hidden, the library draws nothing: an edit kept while editing waits for it to open.
          thumbnails={open ? thumbnails : null}
          selected={selection.selected}
          focusKey={focusKey}
          onPress={press}
          onOpen={openKey}
          onRate={rate}
          onMenu={showMenu}
          onKeyDown={keyDown}
          contentKey={`${scope.folderId}/${scope.path}`}
          reflowKey={`${filters.sort}|${filters.minRating}|${filters.editedOnly}|${search}`}
        >
          {!photos.length &&
            !scopeFolders.some((item) => item.status === "scanning") && (
              <EmptyState
                folders={scopeFolders}
                filtered={filtered && total > 0}
                onAdd={() => addFolder()}
                onClear={() =>
                  setFilters((current) => ({
                    ...noFilters,
                    sort: current.sort,
                  }))
                }
              />
            )}
        </PhotoGrid>
      </motion.div>
      <input
        ref={upload}
        type="file"
        webkitdirectory=""
        hidden
        onChange={async (event) => {
          const id = await library.addUploadedFiles(event.target.files, {
            negative: event.target.dataset.negative === "true",
          });
          event.target.value = "";
          if (id) setScope({ folderId: id, path: "" });
        }}
      />
      <PhotoMenu
        menu={menu}
        targets={menuPhotos}
        actions={fileActions(menuPhotos)}
        selected={selection.selected}
        onAction={menuAction}
        onClose={() => setMenu(null)}
      />
      <DialogContainer onDismiss={() => setRenaming(null)}>
        {renaming && (
          <RenameDialog
            photo={renaming}
            onRename={(name) => rename(renaming, name)}
          />
        )}
      </DialogContainer>
      <DialogContainer onDismiss={() => setTrashing(null)}>
        {trashing && (
          <AlertDialog
            title={
              trashing.length === 1
                ? `Move “${trashing[0].name}” to the Trash?`
                : `Move ${trashing.length} photos to the Trash?`
            }
            variant="destructive"
            primaryActionLabel={fileActions(trashing)?.trash ?? "Move to Trash"}
            cancelLabel="Cancel"
            onPrimaryAction={() => trash(trashing)}
          />
        )}
      </DialogContainer>
      <DialogContainer onDismiss={() => setRemoving(null)}>
        {removing && (
          <AlertDialog
            title={`Remove “${removing.name}”?`}
            variant="destructive"
            primaryActionLabel="Remove"
            cancelLabel="Cancel"
            onPrimaryAction={() => library.removeFolder(removing.id)}
          >
            Fotufilm forgets this folder with its ratings and saved edits. The
            files themselves are not changed.
          </AlertDialog>
        )}
      </DialogContainer>
    </motion.section>
  );
}
