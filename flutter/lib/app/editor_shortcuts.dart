// The keyboard (web/src/editor/useEditorShortcuts.js), and the one order a key goes through:
//
//   1. A focused text field types, and keeps its own editing keys (⌘Z, ⌘X, ⌘C, ⌘V, ⌘A); the
//      editor's single keys and Esc leave it alone.
//   2. The photo library, while it is shown, takes its keys first: its grid has the focus
//      (photo_library_view.dart). Of the editor's keys only L, which hides it, still answers.
//   3. The viewer, while it has the keyboard (a click on a movie gives it) and shows a movie:
//      the player's Space, K, J, L, ←, → and M (video_controls.dart `VideoKeys`, after
//      usePlayerShortcuts.js, which stops them reaching the editor). There Space plays rather
//      than compares and L skips forward rather than showing the library, as in React; with the
//      keyboard anywhere else they are the editor's.
//   4. The canvas tools: Return applies the crop, and Esc leaves it.
//   5. The editor's keys: L, H, C, 0, + and − alone; Space held compares; Esc chooses the shown
//      photo alone, ends the comparison and fits the photograph; ⌘A chooses every open photo and
//      ⌘S exports, as in the web editor.
//   6. The menus' key equivalents (commands.dart), with Ctrl for ⌘ on Linux and Windows; one
//      whose command does not apply now goes nowhere, as the CEF host's menus swallow it.
//
// While a dialog is up, or an export runs, only the menus' keys answer, and Esc closes the dialog.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../ui/kit/popover.dart' show dismissTopModal, openModals;
import 'commands.dart';
import 'host_window.dart';

class EditorShortcuts {
  EditorShortcuts(this.commands);
  final EditorCommands commands;

  EditorModel get editor => commands.editor;

  KeyEventResult handle(KeyEvent event) {
    // Space let go ends the comparison, wherever the keys went.
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.space) editor.setComparing(false);
      return KeyEventResult.ignored;
    }
    // Esc closes a dialog the keys reached the editor past.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        openModals.value > 0 &&
        dismissTopModal()) {
      return KeyEventResult.handled;
    }
    if (!textFieldFocused() && openModals.value == 0 && !editor.exporting) {
      if (_editorKey(event) == KeyEventResult.handled) return KeyEventResult.handled;
    }
    return commands.handleKey(event);
  }

  KeyEventResult _editorKey(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final mac = HostWindow.commandKeyIsMeta;
    final command = mac ? keys.isMetaPressed : keys.isControlPressed;
    final alone = !command && !keys.isAltPressed && !(mac && keys.isControlPressed);
    // ⌘ and nothing else: ⌃⌘S is the View menu's Film Stocks, not Export.
    final plainCommand =
        command && !keys.isAltPressed && !keys.isShiftPressed && !(mac && keys.isControlPressed);
    final key = event.logicalKey;
    // Held keys repeat: a zoom goes on zooming, a switch is pressed once.
    final pressed = event is KeyDownEvent;
    bool handled(void Function() action, {bool repeats = false}) {
      if (pressed || repeats) action();
      return true;
    }

    final active = editor.active != null;
    final crop = editor.crop;
    final done = switch (key) {
      LogicalKeyboardKey.keyL when alone => handled(editor.library.toggle),
      _ when editor.library.open => false,
      // Every open photo, for Paste Settings and presets.
      LogicalKeyboardKey.keyA when plainCommand && editor.documents.length > 1 =>
        handled(editor.selection.selectAll),
      // The web editor's Export; the menu's is ⌘E.
      LogicalKeyboardKey.keyS when plainCommand && active =>
        handled(commands.actions.export),
      LogicalKeyboardKey.space when active => handled(() => editor.setComparing(true), repeats: true),
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter when crop.showing =>
        handled(crop.done),
      LogicalKeyboardKey.escape => handled(() {
          editor.selection.clear();
          editor.setComparing(false);
          if (active) editor.setZoom(null);
          if (crop.showing) crop.leave();
        }),
      LogicalKeyboardKey.keyH when alone => handled(editor.toggleHistogram),
      LogicalKeyboardKey.keyC when alone && active => handled(() => editor.setPanel(Panel.crop)),
      LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 when alone && active =>
        handled(() => editor.setZoom(null)),
      LogicalKeyboardKey.equal || LogicalKeyboardKey.add || LogicalKeyboardKey.numpadAdd
          when alone && active =>
        handled(editor.zoomIn, repeats: true),
      LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract when alone && active =>
        handled(editor.zoomOut, repeats: true),
      _ => false,
    };
    return done ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}

/// A shortcut written the Mac way (⇧⌘Z) as the platform writes it: unchanged on a Mac, and
/// Ctrl+Shift+Z on Linux and Windows (shortcut-label.js `shortcutLabel`).
String shortcutLabel(String keys, {bool? mac}) {
  if (mac ?? HostWindow.commandKeyIsMeta) return keys;
  const modifiers = [('⌃', 'Ctrl'), ('⌘', 'Ctrl'), ('⌥', 'Alt'), ('⇧', 'Shift')];
  final held = {for (final (symbol, name) in modifiers) if (keys.contains(symbol)) name};
  final key = modifiers.fold(keys, (rest, m) => rest.replaceAll(m.$1, ''));
  return [...held, key].join('+');
}

/// The Keyboard shortcuts dialog's rows, as ShortcutsDialog.jsx words them. Export's is the
/// File menu's ⌘E, as on the desktop (shortcut-label.js `exportShortcut`).
List<(String, String)> shortcutRows(EditorModel editor, {bool? mac}) {
  final apple = mac ?? HostWindow.commandKeyIsMeta;
  String label(String keys) => shortcutLabel(keys, mac: apple);
  return [
    ('Open images', label('⌘O')),
    ('Export', label('⌘E')),
    ('Undo', label('⌘Z')),
    ('Redo', label('⇧⌘Z')),
    (editor.catalogue.control('autoAdjustment')['title'] as String, label('⇧⌘A')),
    ('Compare photo', 'Hold Space'),
    ('Show negative', label('⌥⌘N')),
    ('Copy settings', label('⌥⌘C')),
    ('Paste settings', label('⌥⌘V')),
    ('Choose more photos in the strip', 'Shift-click / ${apple ? '⌘' : 'Ctrl'}-click'),
    ('Choose every open photo', label('⌘A')),
    ('Video play / pause', 'Space / K in viewer'),
    ('Video seek', '← / → or J / L in viewer'),
    ('Mute video preview', 'M in viewer'),
    ('Histogram', 'H'),
    ('Crop', 'C'),
    ('Apply crop', 'Return'),
    ('Zoom', '+ / −'),
    ('Fit', '0'),
    ('Reset adjustment', 'Double-click slider'),
  ];
}
