// Choose Film Per Photo, as the Mac app does it (web/src/editor/useFilmSuggestion.js): with the
// `autoFilm` setting on, a photograph shown for the first time is ranked against every film and
// takes the best, unless its film was changed meanwhile or it opened with a kept edit. The film a
// photograph settles on is recorded, so the ranking learns this person's taste.
import 'dart:async';

import 'edit.dart';
import 'editor.dart';

class FilmSuggestion {
  FilmSuggestion(this.editor) {
    editor.addListener(_follow);
    editor.settings.addListener(_follow);
  }

  final EditorModel editor;

  /// Photographs opened with a kept edit, and those already ranked.
  final _kept = Expando<bool>('kept');
  final _suggested = Expando<bool>('suggested');

  Timer? _record;
  (PhotoDocument, String)? _recording;

  /// What the engine learns a photograph's choice under.
  static String photoID(PhotoDocument doc) => doc.identity ?? doc.path;

  /// A photograph is opening, with a kept edit (`saved`) or a new one; it is ranked once shown.
  void opened(PhotoDocument doc, {required bool saved}) => _kept[doc] = saved;

  void _follow() {
    final doc = editor.active;
    if (doc == null) return;
    _suggest(doc);
    _settle(doc);
  }

  Future<void> _suggest(PhotoDocument doc) async {
    final engine = editor.engine;
    if (engine == null || editor.settings.get<bool>('autoFilm') != true) return;
    // A negative's film is the one it was shot on, not a look to rank.
    if (doc.edit['negative'] != null || _kept[doc] == true || _suggested[doc] == true) return;
    _suggested[doc] = true;
    final starting = doc.edit['stock'] as String?;
    try {
      final answer = await engine.call('suggestFilm', {
        ...renderRequest(
          catalogue: editor.catalogue,
          handle: doc.handle,
          edit: doc.edit,
          stock: editor.stockById(starting),
          maxEdge: null,
        ),
        'photoID': photoID(doc),
      });
      final best = answer.json['best'] as String?;
      if (best == null || editor.active != doc) return;
      if (doc.edit['stock'] != starting || best == starting) return;
      // A change the app made for the photograph, not a step to undo.
      final before = doc.history.present;
      doc.history.present = copyEdit(before)..['stock'] = best;
      editor.historyChanged(doc, 'replace', before);
    } catch (_) {
      // Without a suggestion the photograph keeps the film it opened on.
    }
  }

  /// The film a photograph settles on, once it has stayed a moment.
  void _settle(PhotoDocument doc) {
    final stock = doc.edit['stock'] as String?;
    final next = stock == null || doc.edit['negative'] != null ? null : (doc, stock);
    if (next?.$1 == _recording?.$1 && next?.$2 == _recording?.$2) return;
    _recording = next;
    _record?.cancel();
    if (next == null) return;
    _record = Timer(const Duration(milliseconds: 1500), () async {
      try {
        await editor.engine?.call('recordFilmChoice', {'photoID': photoID(doc), 'film': stock});
      } catch (_) {
        // Learning is a convenience; the choice stands either way.
      }
    });
  }
}
