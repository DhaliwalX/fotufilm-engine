// What a newly opened photograph starts on (web/src/app-settings.js `newPhotoEdit`), and Choose
// Film Per Photo (web/src/editor/useFilmSuggestion.js, film-learning.js): a photograph opened
// for the first time is ranked against every film and takes the best, and the film it settles
// on is recorded so the ranking learns this person's taste.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'edit.dart';
import 'editor.dart';

/// Settings › Film Model's settings (SettingsDialog.jsx `FILM_MODEL`).
const filmModelSettings = [
  'grainModel',
  'halationModel',
  'estimatedHalation',
  'couplerReach',
  'couplerRedGreen',
  'couplerGreenBlue',
  'couplerSelf',
];

/// `base` (the editor's default edit on the current film) with the starting film, format and film
/// model the settings choose. Films the library lacks are ignored.
Json newPhotoEdit(Json base, AppSettings settings, [Iterable<String>? stockIDs]) {
  final edit = copyEdit(base);
  final profile = edit['profile'] as Map<String, dynamic>;
  Object? setting(String key) => settings.get<Object>(key);
  final film = setting('startingFilm');
  if (film == 'none') {
    edit['stock'] = null;
  } else if (film is String && (stockIDs == null || stockIDs.contains(film))) {
    edit['stock'] = film;
  }
  if (setting('startingFormat') case final String format) edit['format'] = format;
  edit['halationModel'] = setting('halationModel');
  if (setting('grainModel') != AppSettings.defaults['grainModel']) {
    profile['grainModel'] = setting('grainModel');
  }
  if (setting('estimatedHalation') == true) profile['estimatedHalation'] = true;
  if (setting('receiverBands') case final Map bands) {
    profile['screenRedBand'] = bands['red'];
    profile['screenGreenBand'] = bands['green'];
    profile['screenBlueBand'] = bands['blue'];
  }
  for (final key in const ['couplerReach', 'couplerSelf']) {
    if (setting(key) != AppSettings.defaults[key]) profile[key] = setting(key);
  }
  // A pair set on its own starts the photo there; one left linked follows Separation.
  for (final key in const ['couplerRedGreen', 'couplerGreenBlue']) {
    final value = setting(key);
    if (value != null && value != setting('couplerReach')) profile[key] = value;
  }
  return edit;
}

/// Whether Settings › Film Model differs from its defaults (Restore Film Model's state).
bool filmModelAdjusted(AppSettings settings) =>
    filmModelSettings.any((key) => settings.get<Object>(key) != AppSettings.defaults[key]);

/// Choose Film Per Photo, and what the engine has learned (`filmChoices`).
class FilmSuggestion extends ChangeNotifier {
  FilmSuggestion(this.editor) {
    editor.addListener(settle);
  }
  final EditorModel editor;

  /// Whether the engine ranks films (`filmSuggestion`).
  bool get available => editor.engine?.capabilities['filmSuggestion'] == true;

  /// How many choices the engine has learned from; null until it has said.
  int? learned;

  final Set<int> _ranked = {};
  Timer? _record;
  String? _recorded;

  /// What a photograph's choices are kept under: its file's identity, else its path.
  static String photoID(PhotoDocument doc) => doc.identity ?? doc.path;

  Future<void> refresh() async {
    if (!available) return;
    try {
      final answer = await editor.engine!.call('filmChoices');
      learned = (answer.json['observations'] as num?)?.toInt();
      notifyListeners();
    } catch (_) {}
  }

  /// Reset Film Suggestions: nothing learned is left.
  Future<void> forget() async {
    await editor.engine!.call('forgetFilmChoices');
    learned = 0;
    notifyListeners();
  }

  /// A photograph opened for the first time takes the film ranked best, unless its film was
  /// changed meanwhile. A negative's film is the one it was shot on, not a look to rank.
  Future<void> suggest(PhotoDocument doc) async {
    final engine = editor.engine;
    if (engine == null || !available || editor.settings.get<bool>('autoFilm') != true) return;
    if (doc.edit['negative'] != null || !_ranked.add(doc.handle)) return;
    final starting = doc.edit['stock'];
    try {
      final answer = await engine.call('suggestFilm', {
        ...renderRequest(
          catalogue: editor.catalogue,
          handle: doc.handle,
          edit: doc.edit,
          stock: editor.stockById(starting as String?),
          maxEdge: null,
        ),
        'photoID': photoID(doc),
      });
      final best = answer.json['best'] as String?;
      if (best == null || best == starting || editor.active != doc) return;
      if (doc.edit['stock'] != starting) return;
      editor.chooseStock(best);
    } catch (_) {
      // A suggestion is a convenience; the photograph keeps its film.
    }
  }

  /// The film the shown photograph settles on, once it has stayed a moment.
  void settle() {
    final doc = editor.active;
    final stock = doc?.edit['stock'] as String?;
    if (!available || doc == null || stock == null || doc.edit['negative'] != null) {
      _record?.cancel();
      return;
    }
    final key = '${photoID(doc)}\n$stock';
    if (key == _recorded) return;
    _record?.cancel();
    _record = Timer(const Duration(milliseconds: 1500), () async {
      _recorded = key;
      try {
        final answer = await editor.engine!
            .call('recordFilmChoice', {'photoID': photoID(doc), 'film': stock});
        learned = (answer.json['observations'] as num?)?.toInt() ?? learned;
        notifyListeners();
      } catch (_) {}
    });
  }
}
