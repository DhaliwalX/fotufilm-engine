// The driver's commands for editing actions (driver.dart): history, Copy and Paste Settings, the
// strip's selection, presets, kept edits, Auto Adjust and film suggestions.
//
//   {"state": true}                  logs the shown photo, its undo/redo titles and history, the
//                                    chosen photos, the presets and what was copied
//   {"goTo": 2}                      goes to a step of the Edit History
//   {"undo": true} / {"redo": true}  steps back or forward
//   {"activate": 1}                  shows an open photo (a plain click in the strip)
//   {"choose": [1, "shift"]}         a Shift- or ⌘-click ("meta") on a photo of the strip
//   {"selectAll": true} / {"clearSelection": true}   ⌘A and Esc
//   {"copySettings": null}           Copy Settings with the sections last ticked (or a list)
//   {"paste": true}                  Paste Settings onto the chosen photos
//   {"savePreset": "Name"}           saves the shown edit's last-ticked sections as a preset
//   {"applyPreset": "Name"}          applies a preset to the chosen photos
//   {"renamePreset": ["Old", "New"]} / {"deletePreset": "Name"}
//   {"exportLooks": "/path.fotufilmlook"} / {"importLooks": "/path.fotufilmlook"}
//   {"saveEdits": "/path.json"} / {"loadEdits": "/path.json"}
//   {"presetsTab": true}             shows the film library's Presets tab
//   {"dialog": "copySettings"}       opens copySettings, savePreset or presets; {"dialog": null}
//                                    closes it
//   {"auto": true}                   toggles Auto Adjust
//   {"setting": ["autoFilm", true]}  sets an app setting
//   {"quit": true}                   keeps what waits and quits
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../app/workspace.dart';
import '../model/editor.dart';
import '../model/presets.dart';
import '../ui/kit/popover.dart';
import '../ui/workspace/editing_dialogs.dart';

AnchoredOverlay? _dialog;

/// The workspace's context, under the overlay dialogs open in.
BuildContext? _workspace(GlobalKey boundary) {
  BuildContext? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget is Workspace) {
      found = element;
      return;
    }
    element.visitChildElements(visit);
  }

  boundary.currentContext?.visitChildElements(visit);
  return found;
}

void _openDialog(Object? name, EditorModel editor, GlobalKey boundary) {
  _dialog?.close();
  _dialog = null;
  final context = _workspace(boundary);
  if (context == null) return;
  _dialog = switch (name) {
    'copySettings' => showCopySettingsDialog(context, editor),
    'savePreset' => showSavePresetDialog(context, editor),
    'presets' => showPresetsDialog(context, editor),
    _ => null,
  };
}

Future<void> runEditingCommand(
    Map<String, dynamic> c, EditorModel editor, GlobalKey boundary, void Function(String) log) async {
  final presets = editor.presets;
  Preset? named(String name) => presets.list.where((p) => p.name == name).firstOrNull;
  if (c['state'] == true) {
    final doc = editor.active;
    log('state ${jsonEncode({
      'shown': doc?.name,
      'identity': doc?.identity,
      'stock': doc?.edit['stock'],
      'format': doc?.edit['format'],
      'ev': (doc?.edit['params'] as Map?)?['ev'],
      'undo': editor.history.undo,
      'redo': editor.history.redo,
      'history': editor.history.timeline.titles,
      'step': editor.history.timeline.index,
      'chosen': [for (final d in editor.strip.chosen) d.name],
      'presets': [for (final p in presets.list) '${p.name} (${presets.kind(p)})'],
      'copied': presets.copied?.sections,
      'auto': {'active': editor.auto.active, 'busy': editor.auto.busy},
      'error': editor.error,
    })}');
  }
  if (c['goTo'] case final int step) editor.history.goTo(step);
  if (c['undo'] == true) editor.undo();
  if (c['redo'] == true) editor.redo();
  if (c['activate'] case final int index) editor.strip.press(editor.documents[index]);
  if (c['choose'] case [final int index, final String how]) {
    editor.strip.press(editor.documents[index], range: how == 'shift', toggle: how == 'meta');
  }
  if (c['selectAll'] == true) editor.strip.selectAll();
  if (c['clearSelection'] == true) editor.strip.clear();
  if (c.containsKey('copySettings')) {
    presets.copy((c['copySettings'] as List?)?.cast<String>() ?? presets.sections);
  }
  if (c['paste'] == true) presets.paste();
  if (c['savePreset'] case final String name) presets.save(name, presets.sections);
  if (c['applyPreset'] case final String name) presets.applyPreset(named(name)!.id);
  if (c['renamePreset'] case [final String from, final String to]) {
    presets.rename(named(from)!.id, to);
  }
  if (c['deletePreset'] case final String name) presets.delete(named(name)!.id);
  if (c['exportLooks'] case final String path) {
    await presets.exportTo(path, [for (final p in presets.list) p.id]);
  }
  if (c['importLooks'] case final String path) {
    log('imported ${await presets.import([(path.split('/').last, File(path).readAsString)])}');
  }
  if (c['saveEdits'] case final String path) await editor.keptEdits.writeFile(path);
  if (c['loadEdits'] case final String path) {
    await editor.keptEdits.readFile(File(path).readAsString);
  }
  if (c['presetsTab'] case final bool on) editor.setPresetsTab(on);
  if (c.containsKey('dialog')) _openDialog(c['dialog'], editor, boundary);
  if (c['auto'] == true) editor.toggleAutoAdjust();
  if (c['setting'] case [final String key, final Object? value]) editor.settings.set(key, value);
  if (c['quit'] == true) {
    editor.keptEdits.flush();
    // Let the settings reach the disk before the app goes.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }
}
