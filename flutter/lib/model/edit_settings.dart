// Copy Settings, Paste Settings, presets and look files (web/src/edit-settings.js,
// look-files.js). An edit travels by inspector section, the same sections the Mac and iOS apps
// copy (EditorControlSection.transferable in the catalogue's SETTINGS_SECTIONS).
import 'dart:convert';

import 'catalogue.dart';
import 'edit.dart';
import 'saved_edits.dart';

/// A section of the edit that travels: its id, its title and its tab's.
class SettingsSection {
  const SettingsSection(this.id, this.title, this.group, this.groupTitle, this.byDefault);
  final String id, title, group, groupTitle;
  final bool byDefault;
}

List<SettingsSection> settingsSections(Catalogue catalogue) => [
      for (final s in (catalogue.module['SETTINGS_SECTIONS'] as List).cast<Json>())
        SettingsSection(s['id'] as String, s['title'] as String, s['group'] as String,
            s['groupTitle'] as String, s['byDefault'] == true),
    ];

List<String> defaultSections(Catalogue catalogue) =>
    [for (final s in settingsSections(catalogue)) if (s.byDefault) s.id];

/// The catalogue control each of the edit's own keys belongs to, where the names differ.
const _field = {
  'format': 'gauge',
  'filters': 'lensFilterStack',
  'filterMetering': 'metering',
  'lens': 'lensCorrection',
  'medium': 'paper',
  'mediumFollowsFilm': 'paper',
  'perspectiveV': 'perspectiveVertical',
  'perspectiveH': 'perspectiveHorizontal',
  'cropShape': 'crop',
  'ratio': 'crop',
  'ev': 'exposure',
  'temperature': 'warmth',
};

/// The photograph's own: its grain pattern, its clip and a scanned negative's reading, which only
/// another frame of the roll takes.
const photoKeys = ['seed', 'video', 'negative'];

final _sections = Expando<Map<String, String>>('sections');

/// The section an edit key (or a `params` or `profile` field) travels in; null for the
/// photograph's own, and for a field this version does not know.
String? sectionOf(Catalogue catalogue, String key) {
  if (photoKeys.contains(key)) return null;
  final byField = _sections[catalogue] ??= {
    for (final c in catalogue.controls)
      if (c['section'] != null) c['field'] as String: c['section'] as String,
  };
  return byField[_field[key] ?? key];
}

/// Paste Settings, named for the photos chosen in the strip when there are several.
String pasteTitle(int count) => count > 1 ? 'Paste Settings to $count Photos' : 'Paste Settings';

/// Sections of an edit, to paste elsewhere.
class CopiedSettings {
  CopiedSettings(List<String> sections, this.edit) : sections = List.unmodifiable(sections);
  final List<String> sections;
  final Json edit;

  Json toJson() => {'sections': sections, 'edit': edit};

  static CopiedSettings fromJson(Map json) => CopiedSettings(
      (json['sections'] as List).cast<String>(), Map<String, dynamic>.from(json['edit'] as Map));
}

/// `edit` with the sections `settings` carries taken from its edit.
Json pasteSettings(Catalogue catalogue, Json edit, CopiedSettings settings) {
  bool chosen(String key) => settings.sections.contains(sectionOf(catalogue, key));
  final source = settings.edit;
  final pasted = copyEdit(edit);
  for (final key in edit.keys) {
    if (key != 'params' && key != 'profile' && chosen(key) && source.containsKey(key)) {
      pasted[key] = jsonDecode(jsonEncode(source[key]));
    }
  }
  final params = pasted['params'] as Map, sourceParams = (source['params'] as Map?) ?? const {};
  for (final key in (edit['params'] as Map).keys.cast<String>()) {
    if (chosen(key) && sourceParams.containsKey(key)) params[key] = sourceParams[key];
  }
  // A field absent from the profile is at the film's own value, so a chosen section is replaced
  // whole: fields the source left alone are left alone here too.
  pasted['profile'] = <String, dynamic>{
    for (final e in ((edit['profile'] as Map?) ?? const {}).entries)
      if (!chosen(e.key as String)) e.key as String: e.value,
    for (final e in ((source['profile'] as Map?) ?? const {}).entries)
      if (chosen(e.key as String)) e.key as String: e.value,
  };
  return pasted;
}

/// `pasteSettings` as the editor applies it, through the checks a kept edit is opened with.
/// Throws an [EditProblem] when the result cannot be used.
Json pastedEdit(Catalogue catalogue, Json edit, CopiedSettings settings, List<Json> stocks) {
  final pasted = pasteSettings(catalogue, edit, settings);
  // A new film keeps a chosen medium only where it offers one, as choosing the film does.
  if (pasted['stock'] != edit['stock'] && !settings.sections.contains('printPaper')) {
    final stock = stocks.where((s) => s['id'] == pasted['stock']).firstOrNull;
    final media = ((stock?['media'] as List?) ?? const []).map((m) => (m as Map)['id']);
    if (pasted['mediumFollowsFilm'] == true) {
      pasted['medium'] = stock?['filmMedium'];
    } else if (!media.contains(pasted['medium'])) {
      pasted['medium'] = null;
    }
  }
  // A negative stays a negative, read as a film it can be or as none; frames of one roll share
  // their film base and light source with the film.
  if (edit['negative'] != null) {
    final stock = stocks.where((s) => s['id'] == pasted['stock']).firstOrNull;
    if (pasted['stock'] != null && stock?['readsNegative'] != true) pasted['stock'] = edit['stock'];
    if (settings.sections.contains('filmStock') && settings.edit['negative'] != null) {
      pasted['negative'] = settings.edit['negative'];
    }
  }
  return restoreEdit(editText(pasted), catalogue, stocks);
}

// ── Presets ─────────────────────────────────────────────────────────────────────────────────

/// A named [CopiedSettings], kept on this device.
class Preset {
  const Preset(this.id, this.name, this.settings);
  final String id, name;
  final CopiedSettings settings;

  Json toJson() => {'id': id, 'name': name, 'settings': settings.toJson()};

  static Preset fromJson(Map json) => Preset(json['id'] as String, json['name'] as String,
      CopiedSettings.fromJson(json['settings'] as Map));

  Preset renamed(String name) => Preset(id, name, settings);
}

/// Names in the order a person reads them: case aside, and numbers by value ("Look 2" before
/// "Look 10"), as `localeCompare(…, {numeric: true})` sorts them.
int compareNames(String a, String b) {
  final digits = RegExp(r'\d+|\D+');
  final x = digits.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final y = digits.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final m = int.tryParse(x[i]), n = int.tryParse(y[i]);
    final order = m != null && n != null ? m.compareTo(n) : x[i].compareTo(y[i]);
    if (order != 0) return order;
  }
  return x.length.compareTo(y.length);
}

/// JSON with every map's keys in order, so the same settings read the same however they were
/// built (a look file's edit is rebuilt from its text).
String _canonical(Object? value) {
  Object? sorted(Object? v) => switch (v) {
        Map m => {for (final k in m.keys.map((k) => '$k').toList()..sort()) k: sorted(m[k])},
        List l => [for (final e in l) sorted(e)],
        num n when n == n.roundToDouble() => n.toInt(),
        _ => v,
      };
  return jsonEncode(sorted(value));
}

/// `presets` with `incoming` added (edit-settings.js `importPresets`). One the same as a preset
/// already here is left as it is; one whose name is taken by a different preset is added as
/// "Name 2", never replacing it. Answers the list and how many were added.
(List<Preset>, int) mergePresets(
    List<Preset> presets, List<(String, CopiedSettings)> incoming, String Function() newId) {
  final next = [...presets];
  var added = 0;
  for (final (name, settings) in incoming) {
    final text = _canonical(settings.toJson());
    bool named(Preset p) =>
        p.name == name ||
        (p.name.startsWith('$name ') &&
            RegExp(r'^\d+$').hasMatch(p.name.substring(name.length + 1)));
    if (next.any((p) => named(p) && _canonical(p.settings.toJson()) == text)) continue;
    var unique = name;
    for (var n = 2; next.any((p) => p.name == unique); n++) {
      unique = '$name $n';
    }
    next.add(Preset(newId(), unique, settings));
    added++;
  }
  next.sort((a, b) => compareNames(a.name, b.name));
  return (next, added);
}

// ── Look files ──────────────────────────────────────────────────────────────────────────────
//
// Presets shared as a file, `Name.fotufilmlook`. A look carries a preset's sections and the edit
// they are taken from, without what belongs to the photograph it was saved from.
//
//   { "format": "fotufilm-look", "version": 1,
//     "presets": [{ "name": "…", "settings": { "sections": ["filmStock", …], "edit": {…} } }] }

const lookExtension = 'fotufilmlook';
const _lookFormat = 'fotufilm-look';
const _nameLimit = 100;

/// The edit as another photograph would take it.
Json _shareable(Catalogue catalogue, Json edit) {
  final blank = defaultEdit(catalogue, edit['stock'] as String?);
  return {...edit, for (final key in photoKeys) if (blank.containsKey(key)) key: blank[key]};
}

/// The text of a look file holding `presets`.
String lookText(Catalogue catalogue, List<Preset> presets) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': _lookFormat,
      'version': 1,
      'presets': [
        for (final p in presets)
          {
            'name': p.name,
            'settings': {
              'sections': p.settings.sections,
              'edit': _shareable(catalogue, p.settings.edit),
            },
          },
      ],
    });

/// A file name for `presets`: the preset's own name, or one for several.
String lookFileName(List<Preset> presets) {
  var name = '';
  if (presets.length == 1) {
    name = presets.first.name
        .replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceFirst(RegExp(r'^\.+'), '');
    if (name.length > _nameLimit) name = name.substring(0, _nameLimit);
  }
  return '${name.isEmpty ? 'Fotufilm Presets' : name}.$lookExtension';
}

/// The presets a look file holds, each checked as a kept edit is (look-files.js `readLooks`). A
/// look on a film that is not installed is kept, to apply once the film is, and named in
/// `missing` as (name, film). Sections a later version adds are left out. Throws an
/// [EditProblem] when the file is not a look.
({List<(String, CopiedSettings)> presets, List<(String, String)> missing}) readLooks(
    String text, Catalogue catalogue, List<Json> stocks) {
  Object? file;
  try {
    file = jsonDecode(text);
  } on FormatException {
    throw const EditProblem('This file is not a Fotufilm look.');
  }
  if (file is! Map || file['format'] != _lookFormat || file['presets'] is! List) {
    throw const EditProblem('This file is not a Fotufilm look.');
  }
  if (file['version'] != 1) {
    throw const EditProblem('This look was saved by a newer version of Fotufilm.');
  }
  final known = {for (final s in settingsSections(catalogue)) s.id};
  final ids = [for (final s in stocks) s['id'] as String];
  final presets = <(String, CopiedSettings)>[], missing = <(String, String)>[];
  for (final entry in file['presets'] as List) {
    final rawName = entry is Map ? entry['name'] : null;
    var name = rawName is String ? rawName.trim() : '';
    if (name.length > _nameLimit) name = name.substring(0, _nameLimit);
    final settings = entry is Map ? entry['settings'] : null;
    final sections = settings is Map && settings['sections'] is List
        ? [for (final id in settings['sections'] as List) if (known.contains(id)) id as String]
        : <String>[];
    final source = settings is Map ? settings['edit'] : null;
    if (name.isEmpty ||
        sections.isEmpty ||
        source is! Map ||
        (source['stock'] != null && source['stock'] is! String)) {
      throw const EditProblem('This look file is damaged.');
    }
    Json edit;
    try {
      // A film not installed is let through here and reported below.
      edit = parseEdit(editText(Map<String, dynamic>.from(source)), catalogue,
          [...ids, source['stock'] as String?]);
      final stock = stocks.where((s) => s['id'] == edit['stock']).firstOrNull;
      if (stock != null) {
        restoreEdit(editText(edit), catalogue, stocks);
      } else if (edit['stock'] != null) {
        missing.add((name, edit['stock'] as String));
      }
    } on EditProblem catch (e) {
      throw EditProblem('“$name” could not be read. ${e.message}');
    }
    presets.add((name, CopiedSettings(sections, _shareable(catalogue, edit))));
  }
  if (presets.isEmpty) throw const EditProblem('This look file holds no presets.');
  return (presets: presets, missing: missing);
}
