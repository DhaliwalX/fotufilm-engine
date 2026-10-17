// An edit kept as text (web/src/saved-edits.js, editor-state.js `parseEdit`): what Save Edits
// writes, what every photograph is kept with between sessions, and what a look file carries. A
// kept edit is checked before it is used, so a damaged file or a film since removed is reported
// rather than sent to the engine.
import 'dart:convert';

import 'catalogue.dart';
import 'edit.dart';
import 'settings.dart';

/// Why a kept edit could not be used, in words for the error banner.
class EditProblem implements Exception {
  const EditProblem(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The text an edit is kept as; the same as Save Edits writes.
String editText(Json edit) => jsonEncode({'version': 1, 'edit': edit});

/// Save Edits' file: the same, laid out to be read.
String editFileText(Json edit) =>
    const JsonEncoder.withIndent('  ').convert({'version': 1, 'edit': edit});

const _ratios = ['free', 'original', '1:1', '4:5', '5:4', '3:2', '2:3', '4:3', '3:4', '16:9', '9:16'];

bool _finite(Object? v) => v is num && v.isFinite;

/// Whether `points` is a crop: four corners in the unit square, turning one way.
bool validCrop(Object? points) {
  if (points is! List || points.length != 4) return false;
  for (final p in points) {
    if (p is! List || p.length != 2 || !p.every((v) => _finite(v) && v >= 0 && v <= 1)) {
      return false;
    }
  }
  for (var i = 0; i < 4; i++) {
    final a = points[i] as List, b = points[(i + 1) % 4] as List, c = points[(i + 2) % 4] as List;
    final cross = ((b[0] as num) - (a[0] as num)) * ((c[1] as num) - (b[1] as num)) -
        ((b[1] as num) - (a[1] as num)) * ((c[0] as num) - (b[0] as num));
    if (cross <= 0.0001) return false;
  }
  return true;
}

/// A kept edit's text as an edit: every field checked and the missing ones at their defaults
/// (editor-state.js `parseEdit`). `stocks` are the film ids it may name.
Json parseEdit(String text, Catalogue catalogue, Iterable<String?> stocks) {
  Object? saved;
  try {
    saved = jsonDecode(text);
  } on FormatException {
    throw const EditProblem('Unsupported edit file.');
  }
  if (saved is! Map || saved['version'] != 1 || saved['edit'] is! Map) {
    throw const EditProblem('Unsupported edit file.');
  }
  final edit = Map<String, dynamic>.from(saved['edit'] as Map);
  final stock = edit['stock'];
  if (stock != null && (stock is! String || !stocks.contains(stock))) {
    throw const EditProblem('The film in this edit is not installed.');
  }
  final base = defaultEdit(catalogue, stock as String?);
  final params = edit['params'];
  if (params is! Map ||
      !catalogue.sliders.every((s) {
        final value = params[s.key] ??
            (const ['cameraPreflash', 'sceneLightKelvin'].contains(s.key) ? s.def : null);
        return _finite(value) && value >= s.min && value <= s.max;
      })) {
    throw const EditProblem('Invalid adjustment values.');
  }
  final sceneLights = (catalogue.control('sceneLight')['choices'] as List).cast<Json>();
  if (edit['sceneLight'] != null && !sceneLights.any((c) => c['id'] == edit['sceneLight'])) {
    throw const EditProblem('Invalid source illuminant.');
  }
  final selective = edit['selective'];
  if (selective != null &&
      (selective is! Map ||
          !const ['color', 'light', 'subject'].contains(selective['kind']) ||
          selective['params'] is! Map)) {
    throw const EditProblem('Invalid selective adjustments.');
  }
  if (edit['digitalReference'] != null &&
      !const ['reference-exposure', 'graded-print', 'auto-levels']
          .contains(edit['digitalReference'])) {
    throw const EditProblem('Invalid screen conversion.');
  }
  final medium = edit['medium'];
  if (medium != null && (medium is! String || !RegExp(r'^[a-z0-9-]+$').hasMatch(medium))) {
    throw const EditProblem('Invalid output medium.');
  }
  if (edit['mediumFollowsFilm'] != null && edit['mediumFollowsFilm'] is! bool) {
    throw const EditProblem('Invalid output medium.');
  }
  if (edit['halationModel'] != null && !const ['legacy', 'layered'].contains(edit['halationModel'])) {
    throw const EditProblem('Invalid halation model.');
  }
  for (final key in const ['perspectiveV', 'perspectiveH']) {
    final value = edit[key] ?? 0;
    if (!_finite(value) || (value as num).abs() > 15) {
      throw const EditProblem('Invalid perspective correction.');
    }
  }
  if (edit['cropShape'] != null && !const ['rectangle', 'corners'].contains(edit['cropShape'])) {
    throw const EditProblem('Invalid crop shape.');
  }
  final crop = edit['crop'];
  bool rectangular() {
    final c = (crop as List).cast<List>();
    return c[0][0] == c[3][0] && c[1][0] == c[2][0] && c[0][1] == c[1][1] && c[2][1] == c[3][1];
  }

  final seed = edit['seed'];
  if (!validCrop(crop) ||
      (edit['cropShape'] == 'rectangle' && !rectangular()) ||
      !const [0, 1, 2, 3].contains(edit['rotation']) ||
      edit['flip'] is! bool ||
      edit['gradeSpace'] is! bool ||
      edit['localTone'] is! bool ||
      !_finite(edit['straighten']) ||
      (edit['straighten'] as num).abs() > 15 ||
      seed is! int ||
      seed < 0 ||
      seed > 0xffffffff ||
      !_ratios.contains(edit['ratio'])) {
    throw const EditProblem('Invalid frame settings.');
  }
  // The film's own settings (profile-settings.js `parseProfileSettings`).
  final format = edit['format'];
  if (format != null && !catalogue.filmFormats.any((f) => f['id'] == format)) {
    throw const EditProblem('Invalid film format.');
  }
  final profile = edit['profile'] ?? const {};
  if (profile is! Map) throw const EditProblem('Invalid film settings.');
  for (final MapEntry(:key, :value) in profile.entries) {
    final c = catalogue.profileControls.where((c) => c['field'] == key).firstOrNull;
    final scale = c?['scale'] as Map?, curve = c?['curve'] as Map?;
    final valid = switch (c) {
      null => false,
      _ when scale != null => _finite(value) &&
          value >= (scale['admittedMin'] ?? scale['min']) &&
          value <= (scale['admittedMax'] ?? scale['max']),
      _ when curve != null => value is List &&
          value.length == (curve['handles'] as List).length &&
          value.every((v) => _finite(v) && v >= curve['min'] && v <= curve['max']),
      _ when c['kind'] == 'toggle' => value is bool,
      _ when c['choices'] is List => (c['choices'] as List).any((choice) => choice['id'] == value),
      _ => false,
    };
    if (!valid) throw const EditProblem('Invalid film settings.');
  }
  final filters = edit['filters'] ?? const [];
  if (filters is! List) throw const EditProblem('Invalid lens filters.');
  final lens = edit['lens'];
  if (lens != null && (lens is! Map || lens['enabled'] is! bool)) {
    throw const EditProblem('Invalid lens correction.');
  }
  return {
    ...base,
    for (final key in base.keys)
      if (edit.containsKey(key)) key: edit[key],
    'format': format,
    'profile': Map<String, dynamic>.from(profile),
    'filters': List<dynamic>.from(filters),
    'filterMetering': edit['filterMetering'] ?? 'throughTheLens',
    'lens': {...base['lens'] as Map, ...?(lens as Map?)},
    'perspectiveV': edit['perspectiveV'] ?? 0,
    'perspectiveH': edit['perspectiveH'] ?? 0,
    'cropShape': edit['cropShape'] ?? 'corners',
    'medium': medium,
    'mediumFollowsFilm': edit['mediumFollowsFilm'] == true,
    'printFrame': edit['printFrame'] ?? 'none',
    'digitalReference': edit['digitalReference'] ?? 'auto-levels',
    'halationModel': edit['halationModel'] ?? 'legacy',
    'sceneLight': edit['sceneLight'] ?? 'unspecified',
    'selective': selective,
    'params': {for (final s in catalogue.sliders) s.key: (params[s.key] as num?) ?? s.def},
    'negative': edit['negative'],
  };
}

/// A film the engine compiled without its definition: graded, but not rebuilt
/// (stock-settings.js).
bool fixedStockSettings(Json? stock) => (stock?['profile'] as Map?)?['settings'] == 'fixed';

/// A kept edit for the films installed now; throws an [EditProblem] when it cannot be used.
Json restoreEdit(String text, Catalogue catalogue, List<Json> stocks) {
  final edit = parseEdit(text, catalogue, stocks.map((s) => s['id'] as String));
  final stock = stocks.where((s) => s['id'] == edit['stock']).firstOrNull;
  final profiled = edit['format'] != null ||
      (edit['filters'] as List).isNotEmpty ||
      (edit['profile'] as Map).isNotEmpty ||
      (edit['printFrame'] != null && edit['printFrame'] != 'none');
  if (fixedStockSettings(stock) && profiled) {
    throw const EditProblem('This film uses a fixed profile. Reset film settings to use '
        'exposure, grading, output media and export.');
  }
  return edit;
}

/// A newly opened photograph's edit: the default edit on `currentFilm`, with the starting film,
/// format and film model the settings choose (app-settings.js `newPhotoEdit`). Films the
/// library lacks are ignored.
Json newPhotoEdit(Catalogue catalogue, AppSettings settings, String? currentFilm,
    Iterable<String> stockIds) {
  final edit = defaultEdit(catalogue, currentFilm);
  final profile = edit['profile'] as Map;
  final film = settings.get<String>('startingFilm');
  if (film == 'none') {
    edit['stock'] = null;
  } else if (film != null && stockIds.contains(film)) {
    edit['stock'] = film;
  }
  final format = settings.get<String>('startingFormat');
  if (format != null) edit['format'] = format;
  edit['halationModel'] = settings.get<String>('halationModel') ?? 'legacy';
  final grain = settings.get<String>('grainModel');
  if (grain != AppSettings.defaults['grainModel']) profile['grainModel'] = grain;
  if (settings.get<bool>('estimatedHalation') == true) profile['estimatedHalation'] = true;
  final bands = settings.get<Map>('receiverBands');
  if (bands != null) {
    profile['screenRedBand'] = bands['red'];
    profile['screenGreenBand'] = bands['green'];
    profile['screenBlueBand'] = bands['blue'];
  }
  for (final key in const ['couplerReach', 'couplerSelf']) {
    final value = settings.get<Object>(key);
    if (value != AppSettings.defaults[key]) profile[key] = value;
  }
  // A pair set on its own starts the photo there; one left linked follows Separation.
  for (final key in const ['couplerRedGreen', 'couplerGreenBlue']) {
    final value = settings.get<Object>(key);
    if (value != null && value != settings.get<Object>('couplerReach')) profile[key] = value;
  }
  return edit;
}
