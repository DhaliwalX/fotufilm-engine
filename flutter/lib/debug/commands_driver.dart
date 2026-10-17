// The driver's commands for the menus, the keyboard and the More menu (driver.dart):
//
//   {"menu": true}                  logs the menu bar as it would show now: each item's command,
//                                   title, key equivalent, whether it applies (on/off) and ticks
//                                   (✓), the lists the editor fills expanded
//   {"menuState": true}             logs the state sent to the native menu (useNativeCommands.js
//                                   `menuState`) as JSON
//   {"command": "zoomIn"}           runs a menu command as choosing it does, and logs whether it ran
//   {"workspace": true}             logs the panels, the histogram, the comparison, the zoom, the
//                                   library, the chosen photos, the crop and open dialogs
//   {"keyDown": "space"} / {"keyUp": "space"}   holds a key down, and lets it go
//   {"press": [x, y]} / {"release": [x, y]}      a mouse button held on a point, and let go
//   {"more": true}                  opens the toolbar's More menu
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' show FocusManager;

import '../app/commands.dart';
import '../model/editor.dart';
import '../ui/kit/popover.dart' show openModals;
import '../ui/workspace/toolbar.dart' show moreOptionsKey, showMoreOptions;

Future<void> runCommandsCommand(
  Map<String, dynamic> c,
  EditorModel editor,
  void Function(String) log, {
  required Future<void> Function(String name, {required bool down}) key,
}) async {
  final commands = EditorCommands.shown;
  if (commands == null) return;
  if (c['menu'] == true) {
    final state = commands.state();
    for (final menu in commands.menus) {
      _logNode(menu, state, '', log);
    }
  }
  if (c['menuState'] == true) log('menuState ${jsonEncode(commands.state().toJson())}');
  if (c['command'] case final String id) log('command $id ran=${commands.run(id)}');
  if (c['workspace'] == true) {
    final doc = editor.active;
    log('workspace panel=${editor.panel.id} inspector=${editor.inspectorOpen} '
        'films=${editor.filmOpen} histogram=${editor.histogramOpen} comparing=${editor.comparing} '
        'zoom=${editor.view.zoom?.toStringAsFixed(3)} library=${editor.library.open} '
        'chosen=${editor.selection.chosen.length} crop=${editor.crop.showing} '
        'modals=${openModals.value} dialog=${editor.dialogs.open?.name} '
        'negative=${editor.negatives.showNegative} auto=${editor.auto.active} '
        'photo=${doc == null ? '-' : doc.path.split('/').last} stock=${editor.edit['stock']} '
        'undo=${doc?.history.past.length} sampling=${editor.selective.sampling} '
        'focus=${FocusManager.instance.primaryFocus?.debugLabel ?? FocusManager.instance.primaryFocus}');
  }
  if (c['keyDown'] case final String name) await key(name, down: true);
  if (c['keyUp'] case final String name) await key(name, down: false);
  if (c['press'] case [final num x, final num y]) {
    final at = Offset(x.toDouble(), y.toDouble());
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(
        pointer: 7000, position: at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (c['release'] case [final num x, final num y]) {
    final at = Offset(x.toDouble(), y.toDouble());
    GestureBinding.instance
        .handlePointerEvent(PointerUpEvent(pointer: 7000, position: at, kind: PointerDeviceKind.mouse));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (c['more'] == true) {
    final anchor = moreOptionsKey.currentContext;
    if (anchor != null && anchor.mounted) showMoreOptions(anchor, commands);
  }
}

/// One item as the menu would show it, and a submenu's items under it.
void _logNode(MenuNode node, CommandState state, String indent, void Function(String) log) {
  switch (node) {
    case SeparatorNode():
      log('$indent---');
    case CommandNode(:final id, :final title, :final key):
      _logCommand(id, state.title(id, title), key, state, indent, log);
    case NativeNode(:final role, :final title, :final key):
      log('$indent[$role] "$title"${key == null ? '' : ' ${key.label()}'}');
    case SubmenuNode(:final title, :final items, :final list, :final empty):
      log('$indent"$title" ▸');
      final inner = '$indent  ';
      if (list != null) {
        final listed = state.list(list);
        for (final (id, title) in listed) {
          _logCommand(id, title, null, state, inner, log);
        }
        if (listed.isEmpty) log('$inner"$empty" off');
        if (items.isNotEmpty) log('$inner---');
      }
      for (final item in items) {
        _logNode(item, state, inner, log);
      }
  }
}

void _logCommand(String id, String title, KeyEquivalent? key, CommandState state, String indent,
    void Function(String) log) {
  final tip = state.toolTips[id];
  log('$indent${state.isChecked(id) ? '✓ ' : ''}"$title" $id'
      '${key == null ? '' : ' ${key.label()}'} ${state.isEnabled(id) ? 'on' : 'off'}'
      '${tip == null ? '' : ' tip="$tip"'}');
}
