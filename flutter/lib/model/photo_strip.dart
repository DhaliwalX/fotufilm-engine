// The photo strip's photos (web/src/editor/useDocumentActions.js `acceptFiles`, opened-folder.js):
// the open photographs, and beside them the photos that came with one but wait, undecoded, until
// they are chosen. Opening one file brings its folder; opening a library photo brings its roll.
// Waiting photos show the engine's `thumbnail` picture of the file, drawn only once their place in
// the strip is on screen; only the photo chosen is imported.
//
// The open photographs stay the editor's `documents`; the strip only orders them among the
// waiting ones.
import 'package:flutter/foundation.dart';

import 'editor.dart';
import 'library_files.dart';
import 'library_model.dart';

/// One place in the strip: an open photograph, or a photo waiting to be chosen.
class StripItem {
  const StripItem(this.path, {this.doc, this.negative = false});
  final String path;
  final PhotoDocument? doc;

  /// A scanned negative: it opens as one.
  final bool negative;

  bool get waiting => doc == null;
  String get name => path.substring(path.lastIndexOf('/') + 1);
}

class _Entry {
  _Entry(this.path, this.negative);
  String path;
  final bool negative;

  /// Opened once: closing its photograph takes it out of the strip.
  bool opened = false;
}

class PhotoStripModel extends ChangeNotifier {
  PhotoStripModel(this.editor);
  final EditorModel editor;

  /// The strip's photos in the order they came, opened or waiting.
  final List<_Entry> _entries = [];

  /// The edge of a waiting photo's picture (useDocumentActions.js `drawThumbnails`).
  static const thumbnailEdge = 256;

  /// The strip's photos: each open photograph and the waiting ones, in the order they came; a
  /// photograph opened some other way joins at the end.
  List<StripItem> get items {
    final docs = {for (final d in editor.documents) d.path: d};
    final placed = <String>{};
    final items = <StripItem>[];
    for (final entry in _entries) {
      final doc = docs[entry.path];
      if (doc == null && entry.opened) continue;
      placed.add(entry.path);
      items.add(StripItem(entry.path, doc: doc, negative: entry.negative));
    }
    for (final doc in editor.documents) {
      if (!placed.contains(doc.path)) items.add(StripItem(doc.path, doc: doc));
    }
    return items;
  }

  /// Opens files as Open…, the Finder and the command line do: one file with a path brings the
  /// files beside it in its folder, not those of folders below, in name order (`withOpenedFolder`).
  Future<void> open(List<PhotoFile> files) async {
    if (files.length != 1 || files.single.path == null || !libraryFilesAvailable) {
      return editor.openFiles(files);
    }
    final file = files.single, path = file.path!;
    var paths = [path];
    try {
      paths = folderItems(path, await listFolder(path.substring(0, path.lastIndexOf('/')), recursive: false));
    } catch (_) {
      // A folder that cannot be read opens the file alone.
    }
    await openRoll([
      for (final p in paths)
        p == path ? file : PhotoFile(p.substring(p.lastIndexOf('/') + 1), path: p, negative: file.negative),
    ], shown: path);
  }

  /// Puts `files` in the strip and opens the one at `shown`; the others wait in the strip until
  /// they are chosen. Ones already there keep their places.
  Future<void> openRoll(List<PhotoFile> files, {required String shown}) async {
    final known = {for (final e in _entries) e.path, for (final d in editor.documents) d.path};
    for (final file in files) {
      final path = file.path;
      if (path == null || known.contains(path)) continue;
      _entries.add(_Entry(path, file.negative));
    }
    // A photo opened before and closed since comes back.
    for (final entry in _entries) {
      if (files.any((f) => f.path == entry.path)) entry.opened = false;
    }
    notifyListeners();
    final chosen = files.where((f) => f.path == shown).firstOrNull ?? files.firstOrNull;
    if (chosen != null) await _openFile(chosen);
  }

  Future<void> _openFile(PhotoFile file) async {
    await editor.openFiles([file]);
    for (final entry in _entries) {
      if (editor.documents.any((d) => d.path == entry.path)) entry.opened = true;
    }
    notifyListeners();
  }

  /// Shows a photo: an open one at once, a waiting one once it is imported.
  Future<void> choose(StripItem item) async {
    final doc = item.doc;
    if (doc != null) return editor.selectDocument(editor.documents.indexOf(doc));
    await _openFile(PhotoFile(item.name, path: item.path, negative: item.negative));
  }

  /// Closes a photo: an open one's photograph is released, a waiting one leaves the strip.
  Future<void> close(StripItem item) async {
    final doc = item.doc;
    if (doc != null) {
      await editor.closeDocument(editor.documents.indexOf(doc));
    } else {
      _entries.removeWhere((e) => e.path == item.path);
    }
    notifyListeners();
  }

  /// A file renamed in the library keeps its place under its new path.
  void renamed(String from, String to) {
    for (final entry in _entries) {
      if (entry.path == from) entry.path = to;
    }
    notifyListeners();
  }

  /// Files moved to the Trash leave the strip, and their photographs close.
  Future<void> trashed(Set<String> paths) async {
    _entries.removeWhere((e) => paths.contains(e.path));
    for (final doc in [...editor.documents]) {
      if (paths.contains(doc.path)) await editor.closeDocument(editor.documents.indexOf(doc));
    }
    notifyListeners();
  }
}
