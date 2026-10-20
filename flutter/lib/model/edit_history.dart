// The Edit History, named as the Mac app names it: each step is called after what it changed, so
// Undo and Redo say what they will undo, and the history can be read and jumped through (the More
// menu's Edit History, the Edit menu's).
import 'dart:convert';

import 'editor.dart';

/// A film id to the name the film list shows.
typedef FilmNamer = String? Function(String? id);

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

Map _map(Json? edit, String key) => (edit?[key] as Map?) ?? const {};

bool _changed(Json? before, Json? after, List<String> keys) =>
    keys.any((key) => !_same(before?[key], after?[key]));

bool _paramsChanged(Json? before, Json? after, List<String> keys) =>
    keys.any((key) => !_same(_map(before, 'params')[key], _map(after, 'params')[key]));

bool _profileChanged(Json? before, Json? after, bool Function(String field) test) {
  final a = _map(before, 'profile'), b = _map(after, 'profile');
  return {...a.keys, ...b.keys}
      .cast<String>()
      .any((field) => test(field) && !_same(a[field], b[field]));
}

final _grade = RegExp(r'^grade(Shadows|Midtones|Highlights)(Warmth|Tint|Level)$');
final _filmGrain = RegExp(
    r'^(grainMottle|grainModel|film(GrainSize|ColourGrain|RedLayer|GreenLayer|BlueLayer|ScanSoftness))$');
final _bands = RegExp(r'^screen(Red|Green|Blue)Band$');

/// What a step changed: a title, or a film record for a change of film, named when it is shown.
sealed class _Kind {}

class _Titled extends _Kind {
  _Titled(this.title);
  final String title;
}

class _Film extends _Kind {
  _Film(this.id);
  final String? id;
}

/// Edits are never changed in place, so a step's kind is worked out once per pair of states: the
/// menus ask for the whole timeline on every change.
final _kinds = Expando<(Json?, _Kind)>('historyKind');

_Kind _cachedKind(Json? before, Json after) {
  final hit = _kinds[after];
  if (hit != null && identical(hit.$1, before)) return hit.$2;
  final kind = _stepKind(before, after);
  _kinds[after] = (before, kind);
  return kind;
}

_Kind _stepKind(Json? before, Json? after) {
  String? title() {
    if (!_same(before?['format'], after?['format'])) return 'Film Format';
    if (_changed(before, after, const [
      'crop', 'cropShape', 'ratio', 'rotation', 'flip', 'straighten', 'perspectiveV', //
      'perspectiveH',
    ])) {
      return 'Crop & Rotate';
    }
    if (_changed(before, after, const ['filters', 'filterMetering'])) return 'Lens Filters';
    if (_changed(before, after, const ['lens'])) return 'Lens Correction';
    if (_profileChanged(before, after, (f) => f.startsWith('hdr'))) return 'HDR Highlights';
    if (_changed(before, after, const ['sceneLight']) ||
        _paramsChanged(before, after, const ['sceneLightKelvin'])) {
      return 'Source Illuminant';
    }
    if (_changed(before, after, const ['localTone']) ||
        _paramsChanged(before, after, const ['ev', 'highlights', 'shadows', 'cameraPreflash'])) {
      return 'Light';
    }
    if (_paramsChanged(before, after, const ['temperature', 'tint'])) return 'Undertone';
    if (_paramsChanged(before, after, const ['saturation', 'vibrance'])) return 'Color';
    if (_paramsChanged(before, after, const ['grain']) ||
        _profileChanged(before, after, _filmGrain.hasMatch)) {
      return 'Grain';
    }
    if (_changed(before, after, const ['seed'])) return 'Grain Pattern';
    if (_changed(before, after, const ['halationModel']) ||
        _profileChanged(
            before, after, (f) => f.startsWith('halation') || f == 'estimatedHalation')) {
      return 'Halation';
    }
    if (_profileChanged(before, after, (f) => f.startsWith('coupler'))) return 'Couplers';
    if (_profileChanged(before, after, (f) => f.startsWith('chromaticFringe'))) {
      return 'Chromatic Fringe';
    }
    if (_profileChanged(
        before, after, (f) => const ['push', 'bleach', 'expired', 'shutter'].contains(f))) {
      return 'Lab';
    }
    final params = {..._map(before, 'params').keys, ..._map(after, 'params').keys}.cast<String>();
    if (_changed(before, after, const ['gradeSpace']) ||
        params.any((key) => _grade.hasMatch(key) && _paramsChanged(before, after, [key]))) {
      return 'Grade';
    }
    if (_changed(before, after, const ['medium'])) return 'Output Medium';
    if (_profileChanged(before, after, (f) => f == 'printLight')) return 'Viewing Illuminant';
    if (_changed(before, after, const ['digitalReference'])) return 'Screen Conversion';
    if (_profileChanged(before, after, (f) => f == 'screenGrade')) return 'Paper Grade';
    if (_profileChanged(before, after, _bands.hasMatch)) return 'Receiver Bands';
    if (_profileChanged(before, after, (f) => f == 'screenExposure')) return 'Screen Exposure';
    if (_profileChanged(before, after, (f) => f == 'enlarger' || f.startsWith('printer'))) {
      return 'Enlarger';
    }
    if (_profileChanged(before, after, (f) => f == 'printCorrection')) {
      return 'Channel Contrast Match';
    }
    if (_profileChanged(before, after, (f) => f == 'negativeViewing')) return 'Negative Viewing';
    if (_changed(before, after, const ['printFrame'])) return 'Print Frame';
    if (_changed(before, after, const ['printFrameEdgePrinting'])) return 'Edge Printing';
    if (_changed(before, after, const ['printFrameNumber'])) return 'Frame Number';
    if (_changed(before, after, const ['selective'])) return 'Selective';
    if (_changed(before, after, const ['video'])) return 'Video';
    return null;
  }

  if (!_same(before?['stock'], after?['stock'])) return _Film(after?['stock'] as String?);
  return _Titled(title() ?? 'Edit');
}

/// The name of the step from `before` to `after`, checked in the Mac app's order.
String historyTitle(Json? before, Json after, [FilmNamer? filmName]) => switch (
    _cachedKind(before, after)) {
  _Titled(:final title) => title,
  _Film(:final id) => id == null ? 'Normal' : (filmName?.call(id) ?? 'Film'),
};

/// The whole timeline, oldest first, named step by step, and the step standing now.
({List<String> titles, int index}) editTimeline(History history, [FilmNamer? filmName]) {
  final states = [...history.past, history.present, ...history.future];
  return (
    titles: [
      for (final (i, state) in states.indexed)
        i == 0 ? 'Opened' : historyTitle(states[i - 1], state, filmName),
    ],
    index: history.past.length,
  );
}

/// "Undo Lens Correction", or plain "Undo" when there is nothing to undo; likewise Redo.
String undoTitle(History history, [FilmNamer? filmName]) => history.past.isEmpty
    ? 'Undo'
    : 'Undo ${historyTitle(history.past.last, history.present, filmName)}';

String redoTitle(History history, [FilmNamer? filmName]) => history.future.isEmpty
    ? 'Redo'
    : 'Redo ${historyTitle(history.present, history.future.first, filmName)}';

/// The shown photograph's Edit History, for the menus and the toolbar.
class EditHistory {
  EditHistory(this.editor);
  final EditorModel editor;

  String? _filmName(String? id) => editor.stockById(id)?['name'] as String?;

  String get undo {
    final doc = editor.active;
    return doc == null ? 'Undo' : undoTitle(doc.history, _filmName);
  }

  String get redo {
    final doc = editor.active;
    return doc == null ? 'Redo' : redoTitle(doc.history, _filmName);
  }

  /// Every step's title and the one standing now; none without a photograph.
  ({List<String> titles, int index}) get timeline {
    final doc = editor.active;
    return doc == null ? (titles: const [], index: -1) : editTimeline(doc.history, _filmName);
  }

  /// Goes to a step: the timeline stays whole, as a run of undos or redos would leave it.
  void goTo(int index) {
    final doc = editor.active;
    if (doc == null) return;
    editor.endEdit();
    final h = doc.history;
    final states = [...h.past, h.present, ...h.future];
    if (index < 0 || index >= states.length || index == h.past.length) return;
    final before = h.present;
    h.past
      ..clear()
      ..addAll(states.sublist(0, index));
    h.present = states[index];
    h.future
      ..clear()
      ..addAll(states.sublist(index + 1));
    h.group = null;
    editor.historyChanged(doc, 'goTo', before);
  }
}
