// The pipeline tool: the film's development walked a stage at a time. The shown picture develops at
// the chosen stage (the render's `stage`), or as its change from the stage before (`difference`);
// leaving the tool, or changing what the walk depends on, goes back to the finished print.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'catalogue.dart';
import 'editor.dart';

/// Whether the edit departs from the film's own format, filters or profile, which the walk does
/// not follow (profile-settings.js `hasProfileSettings`).
bool hasProfileSettings(Catalogue catalogue, Json edit) {
  final format = edit['format'];
  if (format != null && format != '') return true;
  if (((edit['filters'] as List?) ?? const []).isNotEmpty) return true;
  final profile = (edit['profile'] as Map?) ?? const {};
  return profile.entries.any((entry) {
    final control = catalogue.profileControls.where((c) => c['field'] == entry.key).firstOrNull;
    return control != null &&
        (entry.key == 'halationReturn' ||
            jsonEncode(entry.value) != jsonEncode(Catalogue.profileDefault(control)));
  });
}

class PipelineTool extends ChangeNotifier {
  PipelineTool(this.editor) {
    editor.renderOptionSources.add(_options);
    editor.addListener(_follow);
    scheduleMicrotask(_follow);
  }

  final EditorModel editor;

  /// The walk's stages for the film ({id, label}), from the engine's `stages`.
  List<Json> stages = const [];

  /// The stage on show, or null for the finished print.
  int? stage;

  /// Whether the stage shows as its change from the one before.
  bool difference = false;

  String? _key;
  PhotoDocument? _shown;
  int _generation = 0;

  /// The names the inspector gives the walk's stages, past which the engine's labels serve.
  static const stageNames = [
    'Bypass',
    'Exposure',
    'Flare',
    'Diffusion',
    'Halation',
    'Couplers',
    'Development',
    'Grain',
    'Negative',
    'Output',
  ];

  String stageName(int index) =>
      index < stageNames.length ? stageNames[index] : stages[index]['label'] as String;

  bool get open => editor.panel == Panel.pipeline;

  /// Whether the edit has its own film settings, so the stages are not offered.
  bool get customised => hasProfileSettings(editor.catalogue, editor.edit);

  Json _options(PhotoDocument doc) => open && stage != null
      // A stage is the bare develop, never framed.
      ? {'stage': stage, 'difference': difference, 'printFrame': null}
      : const {};

  /// Follows the editor: asks for the stages while the tool is open, again when the film or its
  /// settings change, and drops the stage when anything it was walked for changes. The develop the
  /// change schedules then reads the finished print.
  void _follow() {
    final edit = editor.edit, doc = editor.active;
    final stock = edit['stock'] ?? (editor.stocks.isEmpty ? null : editor.stocks.first['id']);
    final key = open && editor.engine != null && stock != null
        ? jsonEncode([
            stock,
            edit['medium'],
            edit['halationModel'],
            edit['digitalReference'],
            edit['format'],
            edit['profile'],
            edit['filters'],
          ])
        : null;
    if (!open || doc != _shown || key != _key) {
      stage = null;
      difference = false;
    }
    _shown = doc;
    if (key == _key) return;
    _key = key;
    stages = const [];
    _generation++;
    if (key != null && !customised) _load(stock as String, edit);
  }

  Future<void> _load(String stock, Json edit) async {
    final id = _generation;
    try {
      final answer = await editor.engine!.call('stages', {
        'stock': stock,
        'medium': edit['medium'],
        'halationModel': edit['halationModel'],
        'digitalReference': edit['digitalReference'],
      });
      if (id != _generation) return;
      stages = [
        for (final s in (answer.value as List?) ?? const []) (s as Map).cast<String, dynamic>(),
      ];
      notifyListeners();
    } catch (e) {
      if (id != _generation) return;
      editor.error = '$e';
      notifyListeners();
    }
  }

  /// Shows a stage, or the finished print (null), which also ends the difference.
  void setStage(int? index) {
    if (index == stage && (index != null || !difference)) return;
    stage = index;
    if (index == null) difference = false;
    notifyListeners();
    editor.renderer?.schedule();
  }

  void setDifference(bool on) {
    if (difference == on) return;
    difference = on;
    notifyListeners();
    editor.renderer?.schedule();
  }
}
