// The photo library (web/src/photo-library/usePhotoLibrary.js, the CEF host's library methods in
// cef/src/app/library_methods.cc): the folders the person chose, read in place, their photos and
// per-photo ratings, and the file actions (rename, show in the Finder, move to the Trash). The
// grid's own state (scope, filters, selection) is the view's, as in PhotoLibrary.jsx. Opening a
// photo hands it to the editor with its roll (useLibraryDocuments.js).
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../app/host_window.dart';
import 'editor.dart';
import 'host_thumbnails.dart';
import 'library_files.dart';
import 'library_model.dart';

/// A folder in the library and what was read from it.
class LibraryFolder {
  LibraryFolder({
    required this.id,
    required this.path,
    required this.name,
    required this.added,
    this.negative = false,
  });

  factory LibraryFolder.fromJson(Json json) => LibraryFolder(
        id: json['id'] as String,
        path: json['path'] as String,
        name: json['name'] as String,
        added: (json['added'] as num?)?.toInt() ?? 0,
        negative: json['negative'] == true,
      );

  final String id, path, name;
  final int added;

  /// A folder of scanned negatives: its photos open, and show, as negatives.
  bool negative;

  /// 'scanning', 'ready' or 'error'.
  String status = 'scanning';
  String? error;
  List<LibraryPhoto> photos = const [];

  Json toJson() => {'id': id, 'path': path, 'name': name, 'added': added, 'negative': negative};
}

/// The opened photo's picture flying from its tile to the viewer (LibraryHandoff.jsx).
class LibraryHandoff {
  const LibraryHandoff({required this.image, required this.rect, required this.path});
  final ui.Image image;

  /// The tile's picture on screen, in the window's coordinates.
  final ui.Rect rect;
  final String path;
}

class PhotoLibrary extends ChangeNotifier {
  PhotoLibrary(this.editor) {
    editor.editListeners.add(_edited);
  }
  final EditorModel editor;

  /// The tiles' and the strip's pictures of files, drawn by the engine.
  late final thumbnails = HostThumbnails(() => editor.engine);

  /// The tiles' picture edge: tiles are at most ~280 px, sharp at 2x (thumbnails.js).
  static const thumbnailEdge = 480;

  static const _foldersKey = 'library.folders', _recordsKey = 'library.records';

  bool open = false;
  final List<LibraryFolder> folders = [];
  LibraryRecords records = {};
  String? error;
  LibraryHandoff? handoff;
  bool _started = false;

  /// Shows or hides the library; nothing is read until it is first shown.
  void setOpen(bool value) {
    if (value == open || (value && editor.exporting)) return;
    open = value;
    if (open) _start();
    notifyListeners();
    // The film rows come back into view.
    if (!open) editor.renderer?.developShown();
  }

  void toggle() => setOpen(!open);
  void dismissError() => _set(() => error = null);

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  /// Saved folders show at once and are read again for changes.
  void _start() {
    if (_started) return;
    _started = true;
    _loadRecords();
    for (final item in _savedFolders()) {
      try {
        folders.add(LibraryFolder.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {
        // A record this version cannot read is left out.
      }
    }
    folders.sort((a, b) => a.added.compareTo(b.added));
    for (final folder in folders) {
      scan(folder);
    }
  }

  bool _recordsLoaded = false;

  void _loadRecords() {
    if (_recordsLoaded) return;
    _recordsLoaded = true;
    records = {
      for (final MapEntry(:key, :value)
          in (editor.settings.get<Map>(_recordsKey) ?? const {}).entries)
        key as String: Map<String, dynamic>.from(value as Map),
    };
  }

  List _savedFolders() => editor.settings.get<List>(_foldersKey) ?? const [];

  /// An edit to a library folder's photo marks it edited, for the grid's Edited filter, whether
  /// or not the library has been shown yet.
  void _edited(EditChange change) {
    final key = keyOf(change.doc.path);
    if (key == null) return;
    _loadRecords();
    if (records[key]?['edit'] == true) return;
    records = {...records, key: {...?records[key], 'edit': true}};
    _saveRecords();
    notifyListeners();
  }

  /// The record key of a file in a library folder, whether or not the library has been shown
  /// yet; null for a file outside them.
  String? keyOf(String file) {
    final roots = _started
        ? [for (final f in folders) (f.id, f.path)]
        : [
            for (final item in _savedFolders())
              if (item is Map) (item['id'] as String, item['path'] as String),
          ];
    for (final (id, root) in roots) {
      if (file.startsWith('$root/')) return photoKey(id, file.substring(root.length + 1));
    }
    return null;
  }

  /// A photo's stars, 0 for none.
  int ratingOf(String key) {
    _loadRecords();
    return (records[key]?['rating'] as num?)?.toInt() ?? 0;
  }

  void _saveFolders() =>
      editor.settings.set(_foldersKey, [for (final f in folders) f.toJson()]);
  void _saveRecords() => editor.settings.set(_recordsKey, records);

  LibraryFolder? folderById(String id) => folders.where((f) => f.id == id).firstOrNull;

  /// Reads a folder's photos again. A refresh keeps the photos that did not change.
  Future<void> scan(LibraryFolder folder) async {
    _set(() {
      folder.status = 'scanning';
      folder.error = null;
    });
    try {
      final rows = await listFolder(folder.path);
      final photos = [
        for (final (path, size, modified) in rows)
          LibraryPhoto(
              folderId: folder.id,
              root: folder.path,
              path: path,
              size: size,
              modified: modified,
              negative: folder.negative),
      ];
      final known = {for (final p in folder.photos) p.key: p};
      folder.photos = [
        for (final photo in photos)
          if (known[photo.key] case final old?
              when old.size == photo.size &&
                  old.modified == photo.modified &&
                  old.negative == photo.negative)
            old
          else
            photo,
      ];
      folder.status = 'ready';
    } catch (e) {
      folder
        ..status = 'error'
        ..photos = const []
        ..error = isFolder(folder.path)
            ? 'This folder could not be read.'
            : 'This folder has moved or been deleted.';
    }
    if (folders.contains(folder)) notifyListeners();
  }

  /// Adds the folder at `path` (chosen in the system's folder panel) and answers its id. A folder
  /// already in the library is read again, or becomes a negatives folder when added as one.
  String? addFolder(String path, {bool negative = false}) {
    final normal = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    if (!isFolder(normal)) {
      _set(() => error = 'The folder could not be opened.');
      return null;
    }
    final existing = folders.where((f) => f.path == normal).firstOrNull;
    if (existing != null) {
      if (negative && !existing.negative) {
        markNegative(existing.id, true);
      } else {
        scan(existing);
      }
      return existing.id;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final folder = LibraryFolder(
      id: '${now.toRadixString(36)}-${normal.hashCode.toUnsigned(32).toRadixString(36)}',
      path: normal,
      name: normal.substring(normal.lastIndexOf('/') + 1),
      added: now,
      negative: negative,
    );
    folders.add(folder);
    _saveFolders();
    scan(folder);
    return folder.id;
  }

  /// Marks a folder as holding scanned negatives, or not.
  void markNegative(String id, bool negative) {
    final folder = folderById(id);
    if (folder == null || folder.negative == negative) return;
    folder
      ..negative = negative
      ..photos = [for (final p in folder.photos) p.withNegative(negative)];
    _saveFolders();
    notifyListeners();
  }

  /// Forgets a folder with its ratings; its files are not changed.
  void removeFolder(String id) {
    folders.removeWhere((f) => f.id == id);
    records.removeWhere((key, _) => key.startsWith('$id/'));
    _saveFolders();
    _saveRecords();
    notifyListeners();
  }

  /// Ratings change at once and are kept.
  void rate(Iterable<String> keys, int rating) {
    _loadRecords();
    // A new map, so views sorted by rating see the change.
    records = {...records};
    for (final key in keys) {
      records[key] = {...?records[key], 'rating': rating};
    }
    _saveRecords();
    notifyListeners();
  }

  /// Renames a photo in its folder; its rating follows it, and an open photograph or a waiting
  /// one in the strip keeps its place. Answers its new key, or null when the name was refused.
  Future<String?> renamePhoto(LibraryPhoto photo, String name) async {
    final path = await renameAt(photo.file, name);
    return path == null ? null : keyOf(path);
  }

  /// Renames a file, in a library folder or not; its rating follows it, and an open photograph
  /// or a waiting one in the strip keeps its place. Answers its new path, or null when the name
  /// was refused (the library's notice, or the editor's outside it, says why).
  Future<String?> renameAt(String file, String name) async {
    final String path;
    try {
      path = renameFile(file, name);
    } catch (e) {
      final problem = e is UnsupportedError ? '${file.split('/').last} could not be renamed.' : fileProblem(e);
      open ? _set(() => error = problem) : editor.showError(problem);
      return null;
    }
    final from = keyOf(file), to = keyOf(path);
    for (final folder in folders) {
      if (!file.startsWith('${folder.path}/')) continue;
      folder.photos = [
        for (final p in folder.photos)
          p.file == file
              ? LibraryPhoto(
                  folderId: folder.id,
                  root: folder.path,
                  path: path.substring(folder.path.length + 1),
                  size: p.size,
                  modified: p.modified,
                  negative: p.negative)
              : p,
      ];
    }
    if (from != null && to != null) {
      _loadRecords();
      final record = records.remove(from);
      if (record != null) {
        records[to] = record;
        _saveRecords();
      }
    }
    thumbnails.forget(file);
    for (final doc in editor.documents) {
      if (doc.path == file) doc.path = path;
    }
    editor.strip.renamed(file, path);
    notifyListeners();
    return path;
  }

  /// Moves photos to the Trash; they leave the library with their records, and the strip with
  /// their photographs. Answers the keys of those that went.
  Future<Set<String>> trashPhotos(List<LibraryPhoto> photos) async {
    final gone = await trashFiles([for (final p in photos) p.file]);
    return {for (final p in photos) if (gone.contains(p.file)) p.key};
  }

  /// Moves files to the Trash, in library folders or not; answers the paths that went.
  Future<Set<String>> trashFiles(List<String> files) async {
    final gone = (await HostWindow.trash(files)).toSet();
    for (final folder in folders) {
      if (gone.any((f) => f.startsWith('${folder.path}/'))) {
        folder.photos = [for (final p in folder.photos) if (!gone.contains(p.file)) p];
      }
    }
    final removed = {for (final f in gone) ?keyOf(f)};
    _loadRecords();
    if (records.keys.any(removed.contains)) {
      records.removeWhere((key, _) => removed.contains(key));
      _saveRecords();
    }
    gone.forEach(thumbnails.forget);
    final failed = [for (final f in files) if (!gone.contains(f)) f.split('/').last];
    if (failed.isNotEmpty) {
      final problem =
          '${failed.join(', ')}: ${failed.length == 1 ? 'It' : 'They'} could not be moved to the Trash.';
      open ? error = problem : editor.showError(problem);
    }
    await editor.strip.trashed(gone);
    notifyListeners();
    return gone;
  }

  /// Shows photos in the Finder.
  Future<void> reveal(List<LibraryPhoto> photos) =>
      HostWindow.reveal([for (final p in photos) p.file]);

  /// Opens photos in the editor: one photo with its roll, the photos of its directory, shown
  /// first; several as chosen (PhotoLibrary.jsx `openPhotos`, useLibraryDocuments.js). A photo
  /// of a negatives folder opens as a negative.
  Future<void> openPhotos(List<LibraryPhoto> list,
      {String sort = 'name', LibraryHandoff? handoff}) async {
    if (list.isEmpty || editor.exporting) return;
    final folder = folderById(list.first.folderId);
    final (photos, shown) = openedPhotos(list, folder?.photos ?? const [], records, sort);
    final present = [for (final p in photos) isFile(p.file)];
    final missing = <String>[];
    final files = <PhotoFile>[];
    String? shownFile;
    for (final (index, photo) in photos.indexed) {
      if (!present[index]) {
        if (photo.key == shown || list.contains(photo)) missing.add(photo.name);
        continue;
      }
      if (photo.key == shown) shownFile = photo.file;
      files.add(PhotoFile(photo.name, path: photo.file, negative: photo.negative));
    }
    this.handoff = shownFile == null ? null : handoff;
    setOpen(false);
    if (files.isNotEmpty) await editor.strip.openRoll(files, shown: shownFile ?? files.first.path!);
    if (missing.isNotEmpty) {
      error = [for (final name in missing) '$name is no longer in its folder.'].join(' ');
      notifyListeners();
    }
  }

  void endHandoff() {
    if (handoff == null) return;
    _set(() => handoff = null);
  }
}
