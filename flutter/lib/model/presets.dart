// Copy Settings, Paste Settings and presets (web/src/editor/useSettingsActions.js). A paste or a
// preset goes onto every photo chosen in the strip: the one shown as one step Undo reverses, each
// of the others as a step of its own history, kept as its edit is. Presets and the sections last
// ticked are kept on this device under their own key, apart from the app settings so resetting
// those leaves them; what was copied lasts for the session, as a clipboard does.
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';

import 'edit.dart';
import 'edit_settings.dart';
import 'editor.dart';
import 'saved_edits.dart';

export 'edit_settings.dart' show CopiedSettings, Preset, SettingsSection, pasteTitle;

class Presets {
  Presets(this.editor) {
    final kept = editor.settings.get<Map>(_key);
    sections = ((kept?['sections'] as List?) ?? defaultSections(editor.catalogue)).cast<String>();
    list = [
      for (final p in (kept?['presets'] as List?) ?? const [])
        if (p is Map) Preset.fromJson(p),
    ];
  }

  final EditorModel editor;

  static const _key = 'editPresets';
  static const historyLimit = 100;

  /// The saved presets, by name.
  late List<Preset> list;

  /// The sections last copied or saved, ticked again next time.
  late List<String> sections;

  /// What Copy Settings took, for Paste Settings.
  CopiedSettings? copied;

  /// The film library's Presets tab's search.
  String search = '';

  late final List<SettingsSection> allSections = settingsSections(editor.catalogue);

  void _write() {
    editor.settings.set(_key, {
      'presets': [for (final p in list) p.toJson()],
      'sections': sections,
    });
    editor.notify();
  }

  void setSearch(String value) {
    search = value;
    editor.notify();
  }

  /// The presets whose names match the search.
  List<Preset> get visible =>
      [for (final p in list) if (p.name.toLowerCase().contains(search.trim().toLowerCase())) p];

  // ── Copying and applying ────────────────────────────────────────────────────────────────

  CopiedSettings _take(List<String> chosen) => CopiedSettings(chosen, copyEdit(editor.edit));

  void copy(List<String> chosen) {
    if (editor.active == null) return;
    copied = _take(chosen);
    sections = [...chosen];
    _write();
  }

  void paste() {
    final settings = copied;
    if (settings != null) apply(settings);
  }

  void applyPreset(String id) {
    final preset = list.where((p) => p.id == id).firstOrNull;
    if (preset != null) apply(preset.settings);
  }

  /// Pastes `settings` onto the chosen photos, or the shown one alone.
  void apply(CopiedSettings settings) {
    final shown = editor.active;
    if (shown == null || editor.exporting) return;
    final docs = editor.selection.chosen;
    final failed = <String>[];
    for (final doc in docs) {
      final Json after;
      try {
        after = pastedEdit(editor.catalogue, doc.edit, settings, editor.stocks);
      } on EditProblem catch (e) {
        failed.add(docs.length > 1 ? '${doc.name}: ${e.message}' : e.message);
        continue;
      }
      if (doc == shown) {
        editor.restore(after);
        continue;
      }
      final h = doc.history;
      h.past.add(h.present);
      if (h.past.length > historyLimit) h.past.removeRange(0, h.past.length - historyLimit);
      h
        ..present = after
        ..group = null
        ..future.clear();
      editor.keptEdits.keep(doc);
    }
    if (failed.isNotEmpty) {
      editor.showError(docs.length > 1
          ? 'Applied to ${docs.length - failed.length} of ${docs.length} photos. ${failed.join(' ')}'
          : failed.join(' '));
    }
    editor.notify();
  }

  /// Whether applying `preset` to the shown edit would change nothing (its row reads chosen).
  bool standing(Preset preset) {
    final edit = editor.active?.edit;
    if (edit == null) return false;
    try {
      return editText(pastedEdit(editor.catalogue, edit, preset.settings, editor.stocks)) ==
          editText(edit);
    } on EditProblem {
      return false;
    }
  }

  /// The edit a preset's row shows: the photograph's with the preset pasted on.
  Json? shownWith(Preset preset, Json edit) {
    try {
      return pastedEdit(editor.catalogue, edit, preset.settings, editor.stocks);
    } on EditProblem {
      return null;
    }
  }

  /// The film a preset sets, as its row's second line: none when it leaves the film.
  String kind(Preset preset) {
    if (!preset.settings.sections.contains('filmStock')) return 'Preset';
    final stock = preset.settings.edit['stock'] as String?;
    return stock == null ? 'No film' : (editor.stockById(stock)?['name'] as String? ?? 'Preset');
  }

  // ── Managing ────────────────────────────────────────────────────────────────────────────

  static String _newId() {
    final random = math.Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Saves the shown edit's `chosen` sections as `name`, replacing a preset of that name.
  void save(String name, List<String> chosen) {
    if (editor.active == null) return;
    sections = [...chosen];
    list = [
      for (final p in list) if (p.name != name) p,
      Preset(_newId(), name, _take(chosen)),
    ]..sort((a, b) => compareNames(a.name, b.name));
    _write();
  }

  void delete(String id) {
    list = [for (final p in list) if (p.id != id) p];
    _write();
  }

  /// Renames a preset; one already of that name gives way, as saving over it would.
  void rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    list = [
      for (final p in list)
        if (p.id == id) p.renamed(trimmed) else if (p.name != trimmed) p,
    ]..sort((a, b) => compareNames(a.name, b.name));
    _write();
  }

  // ── Look files ──────────────────────────────────────────────────────────────────────────

  static const _lookTypes = [
    XTypeGroup(label: 'Fotufilm Look', extensions: [lookExtension]),
  ];

  /// Writes presets as a look file where the save panel says.
  Future<void> export(List<String> ids) async {
    final chosen = [for (final p in list) if (ids.contains(p.id)) p];
    if (chosen.isEmpty) return;
    final location = await getSaveLocation(
        suggestedName: lookFileName(chosen), acceptedTypeGroups: _lookTypes);
    if (location != null) await exportTo(location.path, ids);
  }

  Future<void> exportTo(String path, List<String> ids) async {
    final chosen = [for (final p in list) if (ids.contains(p.id)) p];
    try {
      await File(path).writeAsString(lookText(editor.catalogue, chosen));
    } catch (e) {
      editor.showError('The look could not be saved. $e');
    }
  }

  /// Import Looks…: look files chosen in the open panel, added as presets. Answers how many.
  Future<int> importChosen() async {
    final files = await openFiles(acceptedTypeGroups: _lookTypes);
    return import([for (final f in files) (f.name, f.readAsString)]);
  }

  /// Adds the presets look files hold; a note for each film missing and each file not read.
  Future<int> import(List<(String, Future<String> Function())> files) async {
    final notes = <String>[];
    var added = 0;
    for (final (name, read) in files) {
      try {
        final looks = readLooks(await read(), editor.catalogue, editor.stocks);
        final (merged, count) = mergePresets(list, looks.presets, _newId);
        list = merged;
        added += count;
        for (final (preset, film) in looks.missing) {
          notes.add('“$preset” uses $film, which is not installed; it applies once the film is.');
        }
      } on EditProblem catch (e) {
        notes.add('$name: ${e.message}');
      } on FileSystemException catch (e) {
        notes.add('$name: ${e.message}');
      }
    }
    if (added > 0) _write();
    editor.error = notes.isEmpty ? null : notes.join(' ');
    editor.notify();
    return added;
  }
}
