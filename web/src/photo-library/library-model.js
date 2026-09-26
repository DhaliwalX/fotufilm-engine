export const ALL_FOLDERS = "all";

export const LIBRARY_SORTS = [
  { id: "name", label: "Name" },
  { id: "newest", label: "Newest first" },
  { id: "oldest", label: "Oldest first" },
  { id: "rating", label: "Rating" },
];

const collator = new Intl.Collator(undefined, { numeric: true });
const byName = (a, b) =>
  collator.compare(a.name, b.name) ||
  collator.compare(a.path, b.path) ||
  collator.compare(a.key, b.key);
const COMPARE = {
  name: () => byName,
  newest: () => (a, b) => b.modified - a.modified || byName(a, b),
  oldest: () => (a, b) => a.modified - b.modified || byName(a, b),
  rating: (records) => (a, b) =>
    (records.get(b.key)?.rating || 0) - (records.get(a.key)?.rating || 0) ||
    byName(a, b),
};

// The grid's contents: one folder or all of them, filtered and sorted.
export function visiblePhotos(
  folders,
  records,
  {
    folderId = ALL_FOLDERS,
    search = "",
    sort = "name",
    minRating = 0,
    editedOnly = false,
  } = {},
) {
  const query = search.trim().toLowerCase();
  return folders
    .filter((folder) => folderId === ALL_FOLDERS || folder.id === folderId)
    .flatMap((folder) => folder.photos || [])
    .filter((photo) => {
      const record = records.get(photo.key);
      return (
        (!query || photo.path.toLowerCase().includes(query)) &&
        (record?.rating || 0) >= minRating &&
        (!editedOnly || !!record?.edit)
      );
    })
    .sort(COMPARE[sort](records));
}

// Click, Shift-click and Command/Control-click selection over the visible
// order. `anchor` is where the next Shift range starts.
export function nextSelection(
  photos,
  { selected, anchor },
  key,
  { range = false, toggle = false } = {},
) {
  if (range && anchor != null) {
    const keys = photos.map((photo) => photo.key);
    const from = keys.indexOf(anchor),
      to = keys.indexOf(key);
    if (from >= 0 && to >= 0) {
      const span = keys.slice(Math.min(from, to), Math.max(from, to) + 1);
      return {
        selected: new Set(toggle ? [...selected, ...span] : span),
        anchor,
      };
    }
  }
  if (toggle) {
    const next = new Set(selected);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    return { selected: next, anchor: key };
  }
  return { selected: new Set([key]), anchor: key };
}

// Arrow keys move by one tile or one row of the wrapped grid.
export function steppedKey(photos, key, step) {
  if (!photos.length) return null;
  const index = photos.findIndex((photo) => photo.key === key);
  if (index < 0) return photos[0].key;
  return photos[Math.min(photos.length - 1, Math.max(0, index + step))].key;
}
