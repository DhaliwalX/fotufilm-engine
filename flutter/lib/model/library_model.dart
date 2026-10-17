// The photo library's photos and the rules over them, without state or files: which files a
// folder shows, their order, the filters, the subfolder tree, selection and keyboard steps, and
// what opening a photo brings into the strip (web/src/photo-library/library-model.js,
// library-scan.js, media-types.js, web/src/editor/opened-folder.js).
import 'catalogue.dart';

/// Camera RAW extensions (media-types.js `RAW_EXTENSIONS`).
const rawExtensions = [
  'dng', 'cr2', 'cr3', 'crw', 'nef', 'nrw', 'arw', 'srf', 'sr2', 'raf', 'orf', 'ori', 'rw2', //
  'raw', 'rwl', 'pef', 'ptx', 'srw', '3fr', 'fff', 'iiq', 'kdc', 'dcr', 'mrw', 'mos', 'erf',
  'mef', 'mdc', 'x3f',
];
const _imageExtensions = [
  'jpg', 'jpeg', 'png', 'webp', 'avif', 'gif', 'bmp', 'heic', 'heif', 'tif', 'tiff', 'exr', //
];
const _videoExtensions = ['mp4', 'mov', 'm4v', 'webm', 'mkv'];

/// Every extension a library folder shows, chosen by name alone (`LIBRARY_EXTENSIONS`).
const libraryExtensions = {...rawExtensions, ..._imageExtensions, ..._videoExtensions};

/// 'raw', 'image', 'video', or null for a file the library leaves out (`libraryMediaKind`).
String? libraryMediaKind(String name) {
  final extension = name.split('.').last.toLowerCase();
  if (rawExtensions.contains(extension)) return 'raw';
  if (_imageExtensions.contains(extension)) return 'image';
  if (_videoExtensions.contains(extension)) return 'video';
  return null;
}

/// A file as a folder lists it: its path inside the folder, size in bytes and modification time
/// in milliseconds (the CEF host's `listLibraryFolder` rows).
typedef FileRow = (String path, int size, int modified);

/// A photo in a library folder (library-scan.js `photoEntry`).
class LibraryPhoto {
  LibraryPhoto({
    required this.folderId,
    required this.root,
    required this.path,
    required this.size,
    required this.modified,
    this.negative = false,
  })  : name = path.substring(path.lastIndexOf('/') + 1),
        key = photoKey(folderId, path) {
    // "Photo.jpg" before "Photo 2.jpg", and a raw beside its JPEG.
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot + 1) : '';
    order = [stem, extension, path].map(naturalKey).join('\u0000');
    kind = libraryMediaKind(name);
  }

  final String folderId;

  /// The library folder's absolute path; the file is at [file].
  final String root;
  final String path, name, key;
  final int size, modified;

  /// A scanned negative, in a folder of them.
  final bool negative;
  late final String order;
  late final String? kind;

  String get file => '$root/$path';

  /// The directory it sits in within its folder: '' at the folder's top (`photoDirectory`).
  String get directory => path.substring(0, path.lastIndexOf('/').clamp(0, path.length));

  LibraryPhoto withNegative(bool value) => LibraryPhoto(
      folderId: folderId, root: root, path: path, size: size, modified: modified, negative: value);
}

String photoKey(String folderId, String path) => '$folderId/$path';

/// Natural, case-insensitive order ("IMG_9" before "IMG_10"), computed once per photo so sorting
/// compares plain strings.
String naturalKey(String text) =>
    text.toLowerCase().replaceAllMapped(RegExp(r'\d+'), (m) => m[0]!.padLeft(12, '0'));

/// The grid's orders (`LIBRARY_SORTS`).
const librarySorts = [
  ('name', 'Name'),
  ('newest', 'Newest first'),
  ('oldest', 'Oldest first'),
  ('rating', 'Rating'),
];

/// The rating filter's choices.
const libraryRatings = [
  (0, 'Any rating'),
  (1, '★ or more'),
  (2, '★★ or more'),
  (3, '★★★ or more'),
  (4, '★★★★ or more'),
  (5, '★★★★★'),
];

/// Per-photo records, by key: `rating`, and `edit` where an edit is kept.
typedef LibraryRecords = Map<String, Json>;

int ratingOf(LibraryRecords records, String key) =>
    (records[key]?['rating'] as num?)?.toInt() ?? 0;

int _compare(String a, String b) => a.compareTo(b);
int _byName(LibraryPhoto a, LibraryPhoto b) =>
    _compare(a.order, b.order) != 0 ? _compare(a.order, b.order) : _compare(a.key, b.key);

/// Folders' photo lists merged in the chosen order (`sortedPhotos`).
List<LibraryPhoto> sortedPhotos(
    Iterable<List<LibraryPhoto>> lists, LibraryRecords records, String sort) {
  int Function(LibraryPhoto, LibraryPhoto) by = switch (sort) {
    'newest' => (a, b) => b.modified != a.modified ? b.modified.compareTo(a.modified) : _byName(a, b),
    'oldest' => (a, b) => a.modified != b.modified ? a.modified.compareTo(b.modified) : _byName(a, b),
    'rating' => (a, b) {
        final r = ratingOf(records, b.key) - ratingOf(records, a.key);
        return r != 0 ? r : _byName(a, b);
      },
    _ => _byName,
  };
  return [for (final list in lists) ...list]..sort(by);
}

/// The filters over the grid (`filteredPhotos`). `path` narrows a folder to one of its
/// subfolders and everything below it.
List<LibraryPhoto> filteredPhotos(
  List<LibraryPhoto> photos,
  LibraryRecords records, {
  String path = '',
  String search = '',
  int minRating = 0,
  bool editedOnly = false,
}) {
  final query = search.trim().toLowerCase();
  final prefix = path.isEmpty ? '' : '$path/';
  if (prefix.isEmpty && query.isEmpty && minRating == 0 && !editedOnly) return photos;
  return [
    for (final photo in photos)
      if ((prefix.isEmpty || photo.path.startsWith(prefix)) &&
          (query.isEmpty || photo.path.toLowerCase().contains(query)) &&
          ratingOf(records, photo.key) >= minRating &&
          (!editedOnly || records[photo.key]?['edit'] != null))
        photo,
  ];
}

/// A folder in a library folder's tree: its name, path, how many photos it and its subfolders
/// hold, and the subfolders that hold photos.
class FolderNode {
  FolderNode(this.name, this.path);
  final String name, path;
  int count = 0;
  final List<FolderNode> children = [];
}

/// A folder's subfolders that hold photos, by path; the root is '' (`folderTree`).
Map<String, FolderNode> folderTree(List<LibraryPhoto> photos) {
  final root = FolderNode('', '')..count = photos.length;
  final tree = {'': root};
  for (final photo in photos) {
    var parent = root;
    for (var end = photo.path.indexOf('/'); end >= 0; end = photo.path.indexOf('/', end + 1)) {
      final path = photo.path.substring(0, end);
      final node = tree.putIfAbsent(path, () {
        final node = FolderNode(path.substring(parent.path.isEmpty ? 0 : parent.path.length + 1), path);
        parent.children.add(node);
        return node;
      });
      node.count++;
      parent = node;
    }
  }
  for (final node in tree.values) {
    node.children.sort((a, b) => naturalKey(a.name).compareTo(naturalKey(b.name)));
  }
  return tree;
}

/// The grid's chosen photos, and where the next Shift range starts.
class LibrarySelection {
  const LibrarySelection([this.selected = const {}, this.anchor]);
  final Set<String> selected;
  final String? anchor;
}

/// Click, Shift-click and Command-click over the visible order (`nextSelection`).
LibrarySelection nextSelection(List<LibraryPhoto> photos, LibrarySelection current, String key,
    {bool range = false, bool toggle = false}) {
  if (range && current.anchor != null) {
    final keys = [for (final p in photos) p.key];
    final from = keys.indexOf(current.anchor!), to = keys.indexOf(key);
    if (from >= 0 && to >= 0) {
      final span = keys.sublist(from < to ? from : to, (from < to ? to : from) + 1);
      return LibrarySelection(toggle ? {...current.selected, ...span} : span.toSet(), current.anchor);
    }
  }
  if (toggle) {
    final next = {...current.selected};
    if (!next.remove(key)) next.add(key);
    return LibrarySelection(next, key);
  }
  return LibrarySelection({key}, key);
}

/// Arrow keys move by one tile or one row of the wrapped grid (`steppedKey`).
String? steppedKey(List<LibraryPhoto> photos, String? key, int step) {
  if (photos.isEmpty) return null;
  final index = photos.indexWhere((p) => p.key == key);
  if (index < 0) return photos.first.key;
  return photos[(index + step).clamp(0, photos.length - 1)].key;
}

/// What a context menu acts on: the selection when the photo is in it, else the photo alone.
List<LibraryPhoto> menuTargets(List<LibraryPhoto> photos, Set<String> selected, String key) =>
    selected.contains(key)
        ? [for (final p in photos) if (selected.contains(p.key)) p]
        : [for (final p in photos) if (p.key == key) p];

/// What opening `list` brings into the strip, and the photo shown first (`openedPhotos`). One
/// photo opens with its roll: the photos of its directory, not of subfolders below. Several
/// chosen photos open as chosen.
(List<LibraryPhoto>, String?) openedPhotos(List<LibraryPhoto> list, List<LibraryPhoto> folder,
    LibraryRecords records, String sort) {
  if (list.length != 1) return (list, list.firstOrNull?.key);
  final photo = list.single;
  final roll = [for (final p in folder) if (p.directory == photo.directory) p];
  if (!roll.any((p) => p.key == photo.key)) return (list, photo.key);
  return (sortedPhotos([roll], records, sort), photo.key);
}

/// A name the folder can hold and the library will list (RenameDialog.jsx `nameProblem`).
String? nameProblem(String name) {
  if (name.isEmpty) return 'Enter a name.';
  if (RegExp(r'[/\\:]').hasMatch(name)) return 'A name can’t contain “/” or “:”.';
  if (name.startsWith('.')) return 'A name starting with a dot is hidden.';
  return null;
}

/// The strip's files for `path` among `rows`, its folder's files, in the library's name order
/// (opened-folder.js `folderItems`): the folder's paths, or `path` alone when it is not among them.
List<String> folderItems(String path, List<FileRow> rows) {
  final slash = path.lastIndexOf('/');
  final folder = path.substring(0, slash), name = path.substring(slash + 1);
  final entries = [
    for (final (file, size, modified) in rows)
      LibraryPhoto(folderId: 'opened', root: folder, path: file, size: size, modified: modified),
  ];
  if (!entries.any((e) => e.path == name)) return [path];
  return [for (final e in sortedPhotos([entries], const {}, 'name')) e.file];
}

/// Where a photo came from, for the strip's caption, with a home folder written as "~"
/// (opened-folder.js `stripPath`).
String stripPath(String path) => path.replaceFirst(RegExp(r'^/(?:Users|home)/[^/]+(?=/)'), '~');
