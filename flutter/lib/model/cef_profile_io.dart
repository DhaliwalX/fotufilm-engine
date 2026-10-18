// The previous desktop app's profile, read the first time this app runs where it was: its settings,
// presets, saved band sets, panel widths and photo library come over before the editor reads its
// own, and nothing this app has kept already is replaced. The profile itself is left as it was.
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cef_profile/chromium_storage.dart';
import 'cef_profile/leveldb.dart';
import 'cef_profile/profile_import.dart';
import 'editor.dart';

const _imported = 'cefProfile.imported', _pending = 'cefProfile.pendingEdits';
const _folders = 'library.folders', _records = 'library.records';

Directory? _profile() {
  final home = Platform.environment['HOME'] ?? '';
  if (Platform.isMacOS) {
    return Directory('$home/Library/Application Support/Fotufilm Desktop/Default');
  }
  if (Platform.isLinux) {
    final config = Platform.environment['XDG_CONFIG_HOME'];
    return Directory('${config != null && config.isNotEmpty ? config : '$home/.config'}/Fotufilm/Default');
  }
  return null;
}

/// Brings the previous desktop app's profile over, once, before the editor's features read
/// their settings.
void importCefProfile(AppSettings settings, {Directory? profile}) {
  if (settings.isStored(_imported)) return;
  final directory = profile ?? _profile();
  if (directory == null || !directory.existsSync()) return;
  try {
    final local = Directory('${directory.path}/Local Storage/leveldb');
    final library = Directory('${directory.path}/IndexedDB/fotufilm_app_0.indexeddb.leveldb');
    final plan = planProfileImport(
      local.existsSync() ? localStorageItems(readLevelDb(local))[cefOrigin] ?? const {} : const {},
      library.existsSync()
          ? indexedDbRecords(readLevelDb(library))[cefLibraryDatabase] ?? const {}
          : const {},
    );
    applyProfileImport(settings, plan);
    settings.set(_imported, DateTime.now().millisecondsSinceEpoch);
  } on Object catch (error) {
    // Tried again at the next launch.
    debugPrint('The CEF app profile was not imported: $error');
  }
}

/// Writes what `plan` holds where this app keeps it, under what is kept already.
void applyProfileImport(AppSettings settings, ProfileImport plan) {
  plan.settings.forEach((key, value) {
    if (!settings.isStored(key)) settings.set(key, value);
  });
  if (plan.folders.isNotEmpty) {
    final folders = [...?settings.get<List>(_folders)];
    final known = {
      for (final folder in folders.whereType<Map>()) ...[folder['id'], folder['path']],
    };
    folders.addAll(plan.folders.where((f) => !known.contains(f['id']) && !known.contains(f['path'])));
    settings.set(_folders, folders);
  }
  if (plan.records.isNotEmpty) {
    final records = {...?settings.get<Map>(_records)};
    plan.records.forEach((key, record) {
      records[key] = {...record, ...?(records[key] as Map?)};
    });
    settings.set(_records, records);
  }
  plan.keptEdits.forEach((identity, text) {
    if (!settings.isStored('keptEdit:$identity')) settings.set('keptEdit:$identity', text);
  });
  if (plan.pendingEdits.isNotEmpty) {
    settings.set(_pending, {...?settings.get<Map>(_pending), ...plan.pendingEdits});
  }
}

/// Keeps each library photo's imported edit under the identity the engine answers for its file;
/// one whose file cannot be read now (a drive not attached) waits for the next launch.
Future<void> resolveCefEdits(EditorModel editor) async {
  final engine = editor.engine, settings = editor.settings;
  final pending = {...?settings.get<Map>(_pending)};
  if (engine == null || pending.isEmpty) return;
  final keys = pending.keys.toList();
  final paths = [for (final key in keys) (pending[key] as Map)['path'] as String];
  try {
    final answer = await engine.call('fileIdentities', {'paths': paths});
    final identities = (answer.json['identities'] as List?) ?? const [];
    for (var k = 0; k < keys.length && k < identities.length; k++) {
      final identity = identities[k];
      if (identity is! String) {
        // A photo deleted or renamed since, in a folder still there, has no edit to keep.
        final file = File(paths[k]);
        if (!file.existsSync() && file.parent.existsSync()) pending.remove(keys[k]);
        continue;
      }
      final key = 'keptEdit:$identity';
      if (!settings.isStored(key)) settings.set(key, (pending[keys[k]] as Map)['edit']);
      pending.remove(keys[k]);
    }
  } on Object catch (error) {
    debugPrint('The CEF app edits were not resolved: $error');
    return;
  }
  settings.set(_pending, pending.isEmpty ? null : pending);
}
