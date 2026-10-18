// What the previous desktop app kept in its profile, as this app keeps it: its localStorage items
// and its photo library's IndexedDB records. Folder ids and photo keys carry over unchanged. An
// edit the previous desktop app kept under a library key is kept here under the file's identity
// (kept_edits.dart), which only the engine can answer, so it waits as `pendingEdits` until the file
// can be read.
import 'dart:convert';

/// The origin the previous desktop app served the editor from.
const cefOrigin = 'fotufilm://app';

/// The photo library's IndexedDB database.
const cefLibraryDatabase = 'fotufilm-photo-library';

class ProfileImport {
  /// Settings to write, by this app's keys (settings.dart).
  final settings = <String, Object?>{};

  /// Library folders (photo_library.dart `LibraryFolder.toJson`).
  final folders = <Map<String, Object?>>[];

  /// Library photo records by key: ratings, and whether an edit was kept.
  final records = <String, Map<String, Object?>>{};

  /// Kept edits by file identity (kept_edits.dart).
  final keptEdits = <String, String>{};

  /// Kept edits whose identity is still to be found: by library key, the file and the edit.
  final pendingEdits = <String, Map<String, String>>{};
}

/// `items` are the origin's localStorage items; `stores` the library database's object stores.
ProfileImport planProfileImport(Map<String, String> items, Map<String, List<Object?>> stores) {
  final plan = ProfileImport();
  for (final MapEntry(:key, :value) in items.entries) {
    final name = key.startsWith('fotufilm.setting.')
        ? key.substring('fotufilm.setting.'.length)
        : key.startsWith('fotufilm.')
            ? key.substring('fotufilm.'.length)
            : null;
    if (name == null || name.isEmpty) continue;
    try {
      plan.settings[name] = jsonDecode(value);
    } on FormatException {
      // An item this app never wrote as JSON is left behind.
    }
  }

  final roots = <String, String>{};
  for (final folder in (stores['folders'] ?? const []).whereType<Map>()) {
    final id = folder['id'], name = folder['name'], handle = folder['handle'];
    final path = handle is Map ? handle['hostPath'] : null;
    if (id is! String || name is! String || path is! String || path.isEmpty) continue;
    roots[id] = path;
    plan.folders.add({
      'id': id,
      'path': path,
      'name': name,
      'added': (folder['added'] as num?)?.toInt() ?? 0,
      'negative': folder['negative'] == true,
    });
  }

  for (final photo in (stores['photos'] ?? const []).whereType<Map>()) {
    final key = photo['key'];
    if (key is! String) continue;
    final rating = photo['rating'], edit = photo['edit'];
    final identity = key.startsWith('sha256:') || key.startsWith('file:');
    if (identity) {
      if (edit is String) plan.keptEdits[key] = edit;
      continue;
    }
    final split = key.indexOf('/');
    final root = split > 0 ? roots[key.substring(0, split)] : null;
    if (root == null) continue;
    final record = <String, Object?>{
      if (rating is num && rating > 0) 'rating': rating.toInt(),
      if (edit is String) 'edit': true,
    };
    if (record.isNotEmpty) plan.records[key] = record;
    if (edit is String) {
      plan.pendingEdits[key] = {'path': '$root/${key.substring(split + 1)}', 'edit': edit};
    }
  }
  return plan;
}
