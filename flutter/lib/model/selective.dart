// The selective tool (web/src/selective.js): a selection by a colour or a light sampled from the
// photograph, or by its subjects, developed with its own light and colour. The selection is the
// edit's `selective`; sampling and the mask are the tool's, and end when it closes or another
// photograph is shown.
import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import 'editor.dart';

/// The adjustments a selection develops with in place of the photograph's (`selectionKeys`).
final selectionKeys = [
  'ev',
  'temperature',
  'tint',
  'highlights',
  'shadows',
  'saturation',
  'vibrance',
  for (final band in const ['Shadows', 'Midtones', 'Highlights'])
    for (final axis in const ['Warmth', 'Tint', 'Level']) 'grade$band$axis',
];

/// The photograph's develop, as a selection starts with it (`selectionDevelop`).
Json selectionDevelop(Json edit) => {
      'params': {for (final key in selectionKeys) key: (edit['params'] as Map)[key]},
      'localTone': edit['localTone'],
      'gradeSpace': edit['gradeSpace'],
    };

/// A selection before anything is sampled (`newSelection`).
Json newSelection(Json edit) => {
      'kind': 'color',
      'point': null,
      'sample': null,
      'range': 0.25,
      'softness': 0.5,
      ...selectionDevelop(edit),
    };

/// A point on the shown picture as a point on the photograph inside its print frame, or null on
/// the frame's border (print-frame.js `frameSamplePoint`). The plan's image is placed from the
/// bottom.
List<double>? frameSamplePoint(List<double> point, Map? plan) {
  final placement = plan?['placement'] as Map?;
  if (placement == null) return point;
  final size = placement['size'] as Map, image = placement['image'] as Map;
  double n(Map m, String key) => (m[key] as num).toDouble();
  final x = (point[0] * n(size, 'width') - n(image, 'x')) / n(image, 'width');
  final y = (point[1] * n(size, 'height') -
          (n(size, 'height') - n(image, 'y') - n(image, 'height'))) /
      n(image, 'height');
  return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? [x, y] : null;
}

/// What the inspector says of a subject selection's subjects: still looking, none, one or many
/// (from the catalogue's `subjectsFound`).
String subjectsFound(List<String> texts, int? count) => switch (count) {
      null => texts[0],
      0 => texts[1],
      1 => texts[2],
      _ => texts[3].replaceAll('%d', '$count'),
    };

class SelectiveTool extends ChangeNotifier {
  SelectiveTool(this.editor) {
    editor.renderOptionSources.add(_options);
    editor.addListener(_follow);
  }

  final EditorModel editor;

  /// Whether the next click on the photograph samples it.
  bool sampling = false;

  /// Whether the picture shows the selection as a mask (the render's `showMask`).
  bool showMask = false;

  PhotoDocument? _shown;
  int _generation = 0;

  /// The catalogue's labels, choices and ranges (generated/controls.js `SELECTION`).
  Json get spec => editor.catalogue.module['SELECTION'] as Json;

  bool get open => editor.panel == Panel.selective;

  /// The edit's selection, or the one a first change starts.
  Json get selection {
    final saved = editor.edit['selective'];
    return saved is Map ? Map<String, dynamic>.of(saved.cast()) : newSelection(editor.edit);
  }

  bool get subject => selection['kind'] == 'subject';

  /// Colour and light, and subjects where the host detects them.
  List<Json> get choices => [
        for (final c in (spec['choices'] as List).cast<Json>())
          if (c['native'] != true || editor.engine?.capabilities['subjectSelection'] == true) c,
      ];

  /// A picture is on show to sample (`!!shownResult`).
  bool get canSample => editor.active?.shownRequest != null;

  /// How many subjects the shown picture's develop found; null until it says.
  int? get subjects => (editor.active?.shownAnswer?['subjects'] as num?)?.toInt();

  Json _options(PhotoDocument doc) => open && showMask ? const {'showMask': true} : const {};

  /// Another tool or photograph ends sampling and the mask.
  /// The editor is notifying already, and the mask's option reads `open` besides.
  void _follow() {
    final doc = editor.active;
    if ((!open || doc != _shown) && (sampling || showMask)) {
      sampling = showMask = false;
      _generation++;
    }
    _shown = doc;
  }

  /// Sample a Selection: opens the tool and waits for a click on the photograph.
  void startSampling() {
    editor.setPanel(Panel.selective);
    setSampling(true);
  }

  void setSampling(bool on) {
    if (sampling == on) return;
    sampling = on;
    _generation++;
    notifyListeners();
  }

  void setShowMask(bool on) {
    if (showMask == on) return;
    showMask = on;
    notifyListeners();
    editor.renderer?.schedule();
  }

  /// Changes the selection; changes under one `group` (a slider being dragged) make one step.
  void change(Json value, {String? group}) {
    final next = {...selection, ...value};
    if (group == null) {
      editor.change({'selective': next});
    } else {
      editor.patch({'selective': next}, group: group);
    }
  }

  /// Puts the selection's develop back to the photograph's.
  void matchPhotograph() => change(selectionDevelop(editor.edit));

  /// Clear Selection: the edit loses it, and sampling and the mask end.
  void clear() {
    editor.change({'selective': null});
    sampling = showMask = false;
    _generation++;
    notifyListeners();
  }

  /// Samples the undeveloped scene at `at`, a point on the shown picture from 0 to 1 each way,
  /// and selects by it. A sample that comes back after the edit or the picture moved on is
  /// dropped.
  Future<void> sample(List<double> at) async {
    final doc = editor.active, engine = editor.engine, request = doc?.shownRequest;
    if (doc == null || engine == null || request == null || !sampling) return;
    final point = frameSamplePoint(at, doc.shownAnswer?['framePlan'] as Map?);
    if (point == null) return;
    final id = ++_generation;
    final edit = doc.edit;
    bool valid() =>
        id == _generation && sampling && editor.active == doc && identical(doc.edit, edit);
    try {
      final answer = await engine.call('sampleScene', {'render': request, 'point': point});
      final rgb = answer.value;
      if (rgb is! List || rgb.length != 3 || !valid()) return;
      editor.change({
        'selective': {
          ...selection,
          'point': point,
          'sample': [for (final c in rgb) (c as num).toDouble()],
        },
      });
      sampling = false;
      notifyListeners();
    } on FotufilmCancelled {
      // A newer develop took the engine; the next click samples again.
    } catch (e) {
      if (valid()) {
        editor.error = '$e';
        notifyListeners();
      }
    }
  }
}
