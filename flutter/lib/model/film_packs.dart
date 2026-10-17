// Import Film Pack, as the Mac app's File menu has it (web/src/editor/useFilmPacks.js): a
// community pack goes into the library this person's films live in, the engine reloads its films
// and the film list follows. Each result reads as the Mac app's alert does ("Pack added",
// "Test Pack v1 — 3 films"). A host without `filmPacks` offers none of it.
import 'package:flutter/foundation.dart';

import 'app_dialogs.dart';
import 'editor.dart';

const filmPackExtension = 'fotufilmpack';

bool isFilmPack(String name) => name.toLowerCase().endsWith('.$filmPackExtension');

/// What an import said: the alert's title and message, whether the pack went in, and whether it
/// needs a newer Fotufilm.
class PackNotice {
  const PackNotice(this.title, this.message, {this.added = false, this.update = false});
  final String title, message;
  final bool added, update;

  factory PackNotice.from(Json result) => PackNotice(
        result['title'] as String? ?? '',
        result['message'] as String? ?? '',
        added: result['added'] == true,
        update: result['update'] == true,
      );

  /// One notice for everything that arrived together (`packNotice`).
  factory PackNotice.of(List<PackNotice> results) {
    if (results.length == 1) return results.first;
    return PackNotice(
      results.every((r) => r.added) ? 'Packs added' : 'Film packs',
      results.map((r) => '${r.title}: ${r.message}').join('\n\n'),
      added: results.any((r) => r.added),
      update: results.any((r) => r.update),
    );
  }
}

class FilmPacks extends ChangeNotifier {
  FilmPacks(this.editor);
  final EditorModel editor;

  bool get available => editor.engine?.capabilities['filmPacks'] == true;

  /// The installed packs (`{packID, name, version?, films, stocks, problem?}`); null until read.
  List<Json>? installed;

  /// The last import's alert, for the notice dialog.
  PackNotice? notice;

  Future<Json> _call(String method, [Json params = const {}]) async =>
      (await editor.engine!.call(method, params)).json;

  /// The installed packs, read afresh: another app may have added or removed one, in which case
  /// the engine has reloaded its films and the film list asks again.
  Future<List<Json>> refresh() async {
    if (!available) return const [];
    final answer = await _call('filmPacks');
    final packs = ((answer['packs'] as List?) ?? const []).cast<Json>();
    if (answer['changed'] == true) await _filmsChanged();
    installed = packs;
    notifyListeners();
    return packs;
  }

  /// At launch, installed packs this release cannot read offer the update, as the Mac app does.
  Future<void> launch() async {
    if (!available) return;
    try {
      final answer = await _call('filmPacks');
      final incompatible = ((answer['incompatible'] as List?) ?? const []).cast<String>();
      if (incompatible.isNotEmpty) {
        _show(PackNotice('Update Fotufilm to use this pack', incompatible.join('\n\n'),
            update: true));
      }
      await refresh();
    } catch (_) {}
  }

  /// Installs packs by path. `quiet` leaves showing the results to the caller (Settings shows
  /// them in place); otherwise they appear as the Mac app's alert.
  Future<List<PackNotice>> importPaths(List<String> paths, {bool quiet = false}) async {
    if (!available || editor.exporting || paths.isEmpty) return const [];
    final results = <PackNotice>[];
    var changed = false;
    for (final path in paths) {
      try {
        final answer = await _call('importFilmPack', {'path': path});
        if (answer['added'] == true) {
          changed = true;
          installed = ((answer['packs'] as List?) ?? const []).cast<Json>();
        }
        results.add(PackNotice.from(answer));
      } catch (e) {
        results.add(PackNotice('Pack not added', '${path.split('/').last}: $e'));
      }
    }
    if (changed) await _filmsChanged();
    notifyListeners();
    if (!quiet) _show(PackNotice.of(results));
    return results;
  }

  /// Removes a pack with its films. A photo on one of them goes back to no film rather than to a
  /// film that is gone.
  Future<void> remove(String packID) async {
    if (!available || editor.exporting) return;
    final removed = installed?.where((p) => p['packID'] == packID).firstOrNull;
    final answer = await _call('removeFilmPack', {'packID': packID});
    if (((removed?['stocks'] as List?) ?? const []).contains(editor.edit['stock'])) {
      editor.chooseStock(null);
    }
    installed = ((answer['packs'] as List?) ?? const []).cast<Json>();
    await _filmsChanged();
    notifyListeners();
  }

  /// The engine has reloaded its films: the library loads them again.
  Future<void> _filmsChanged() => editor.loadStocks();

  void _show(PackNotice next) {
    notice = next;
    notifyListeners();
    editor.dialogs.request(AppDialog.filmPack);
  }
}
