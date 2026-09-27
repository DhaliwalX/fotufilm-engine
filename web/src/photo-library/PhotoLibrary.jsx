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
import { currentFile } from "./library-scan.js";
import {
  ALL_FOLDERS,
  filteredPhotos,
  nextSelection,
  sortedPhotos,
  steppedKey,
} from "./library-model.js";
import { createThumbnails } from "./thumbnails.js";
import { supportsFolderAccess, usePhotoLibrary } from "./usePhotoLibrary.js";
import "./photo-library.css";

const EASE = [0.2, 0.8, 0.2, 1];
const TILE_SIZE_KEY = "fotufilm.library.tileSize";
const noFilters = { search: "", sort: "name", minRating: 0, editedOnly: false };

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
// {key, name, file, edit} per photo, `edit` being the text saved with
// saveLibraryEdit, and the first tile's on-screen rectangle and thumbnail.
export default function PhotoLibrary({ open, onOpenPhotos, onClose }) {
  const library = usePhotoLibrary(open);
  const [thumbnails, setThumbnails] = useState(null);
  const [folderId, setFolderId] = useState(ALL_FOLDERS);
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
  const upload = useRef(null),
    grid = useRef(null);

  useEffect(() => {
    const cache = createThumbnails();
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

  const folder = library.folders.find((item) => item.id === folderId);
  if (folderId !== ALL_FOLDERS && !folder) setFolderId(ALL_FOLDERS);
  const scopeFolders = folder ? [folder] : library.folders;

  const search = useDeferredValue(filters.search);
  const lists = useSameItems(scopeFolders.map((item) => item.photos));
  const sortRecords = filters.sort === "rating" ? library.records : null;
  const sorted = useMemo(
    () => sortedPhotos(lists, sortRecords, filters.sort),
    [lists, sortRecords, filters.sort],
  );
  const photos = useMemo(
    () => filteredPhotos(sorted, library.records, { ...filters, search }),
    [sorted, library.records, filters, search],
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

  const addFolder = async () => {
    if (!supportsFolderAccess()) return upload.current.click();
    const id = await library.addFolder();
    if (id) setFolderId(id);
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
          edit: library.records.get(photo.key)?.edit ?? null,
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
        folderId={folderId}
        total={total}
        onSelect={(id) => {
          setFolderId(id);
          setSelection({ selected: new Set(), anchor: null });
        }}
        onAdd={addFolder}
        onRescan={library.rescan}
        onRemove={setRemoving}
      />
      <motion.div
        className="library-main"
        initial={false}
        animate={open ? { scale: 1, y: 0 } : { scale: 0.992, y: 6 }}
        transition={{ duration: 0.26, ease: EASE }}
      >
        <LibraryBar
          title={folder?.name ?? "All Photos"}
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
          thumbnails={thumbnails}
          selected={selection.selected}
          focusKey={focusKey}
          onPress={press}
          onOpen={openKey}
          onRate={rate}
          onKeyDown={keyDown}
          contentKey={folderId}
          reflowKey={`${filters.sort}|${filters.minRating}|${filters.editedOnly}|${search}`}
        >
          {!photos.length &&
            !scopeFolders.some((item) => item.status === "scanning") && (
              <EmptyState
                folders={scopeFolders}
                filtered={filtered && total > 0}
                onAdd={addFolder}
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
          const id = await library.addUploadedFiles(event.target.files);
          event.target.value = "";
          if (id) setFolderId(id);
        }}
      />
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
