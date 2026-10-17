// The editor's commands, listed once. On macOS they are the menu bar with ⌘ shortcuts; on Linux
// and Windows the same shortcuts answer with Ctrl. The shortcuts dialog lists them from here too.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../model/presets.dart' show pasteTitle;
import '../ui/workspace/editing_dialogs.dart';
import 'host_window.dart';

class Command {
  const Command(this.label, this.run,
      {this.key, this.shift = false, this.alt = false, this.submenu});

  final String label;

  /// The commands of a submenu (Edit History, Presets); the command itself does not run.
  final List<List<Command>>? submenu;

  /// Null while the command does not apply.
  final VoidCallback? run;
  final LogicalKeyboardKey? key;
  final bool shift, alt;

  static bool get _mac => HostWindow.commandKeyIsMeta;

  SingleActivator? get activator => key == null
      ? null
      : SingleActivator(key!, meta: _mac, control: !_mac, shift: shift, alt: alt);

  /// The shortcut as the platform writes it: ⌥⇧⌘Z, or Ctrl+Alt+Shift+Z.
  String? get keys {
    final key = this.key;
    if (key == null) return null;
    final name = switch (key) {
      LogicalKeyboardKey.equal => '=',
      LogicalKeyboardKey.minus => '−',
      _ => key.keyLabel.toUpperCase(),
    };
    if (_mac) return '${alt ? '⌥' : ''}${shift ? '⇧' : ''}⌘$name';
    return ['Ctrl', if (alt) 'Alt', if (shift) 'Shift', name].join('+');
  }
}

class CommandMenu {
  const CommandMenu(this.label, this.groups);
  final String label;

  /// Commands in groups, divided in the menu.
  final List<List<Command>> groups;

  Iterable<Command> get commands => groups.expand((g) => g);
}

/// Every command, by menu.
List<CommandMenu> editorCommands(
  EditorModel editor, {
  required VoidCallback open,
  required VoidCallback export,
  BuildContext? context,
}) {
  final photo = editor.active != null;
  VoidCallback? when(bool enabled, VoidCallback run) => enabled ? run : null;
  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
  ];
  return [
    CommandMenu('File', [
      [
        Command('Open…', when(editor.ready, open), key: LogicalKeyboardKey.keyO),
        Command('Close Photo', when(photo, () => editor.closeDocument(editor.activeIndex)),
            key: LogicalKeyboardKey.keyW),
      ],
      [Command('Export…', when(photo, export), key: LogicalKeyboardKey.keyE)],
    ]),
    CommandMenu('Edit', [
      [
        Command(editor.history.undo, when(editor.canUndo, editor.undo),
            key: LogicalKeyboardKey.keyZ),
        Command(editor.history.redo, when(editor.canRedo, editor.redo),
            key: LogicalKeyboardKey.keyZ, shift: true),
        // Every step of the shown photograph's history; choosing one goes to it.
        Command('Edit History', null, submenu: [
          [
            for (final (i, title) in editor.history.timeline.titles.indexed)
              Command(title, () => editor.history.goTo(i)),
            if (editor.active == null) const Command('No Open Edit', null),
          ],
        ]),
      ],
      [
        Command('Reset All Edits', when(editor.edited, editor.resetEdit)),
        Command(editor.auto.busy ? 'Cancel Auto Adjust' : 'Auto Adjust',
            when(photo && editor.auto.available, editor.toggleAutoAdjust),
            key: LogicalKeyboardKey.keyA, shift: true),
      ],
      // Copy Settings, Paste Settings and presets (editing_dialogs.dart).
      if (context != null)
        [
          Command('Copy Settings…', when(photo, () => showCopySettingsDialog(context, editor)),
              key: LogicalKeyboardKey.keyC, alt: true),
          Command(pasteTitle(editor.strip.chosen.length),
              when(photo && editor.presets.copied != null, editor.presets.paste),
              key: LogicalKeyboardKey.keyV, alt: true),
          Command('Presets', null, submenu: [
            [
              for (final preset in editor.presets.list)
                Command(preset.name, when(photo, () => editor.presets.applyPreset(preset.id))),
              if (editor.presets.list.isEmpty) const Command('No Presets', null),
            ],
            [
              Command('Save Preset…', when(photo, () => showSavePresetDialog(context, editor))),
              Command('Manage Presets…',
                  when(editor.presets.list.isNotEmpty, () => showPresetsDialog(context, editor))),
              Command('Import Looks…', () => importLooks(context, editor)),
            ],
          ]),
        ],
    ]),
    CommandMenu('View', [
      [
        Command('Zoom In', when(photo, editor.zoomIn), key: LogicalKeyboardKey.equal),
        Command('Zoom Out', when(photo, editor.zoomOut), key: LogicalKeyboardKey.minus),
        Command('Zoom to Fit', when(photo, () => editor.setZoom(null)),
            key: LogicalKeyboardKey.digit0),
        Command('Actual Size', when(photo, () => editor.setZoom(1)),
            key: LogicalKeyboardKey.digit1),
      ],
      [
        Command(editor.filmOpen ? 'Hide Film Library' : 'Show Film Library', editor.toggleFilm,
            key: LogicalKeyboardKey.keyL, alt: true),
        Command(editor.inspectorOpen ? 'Hide Adjustments' : 'Show Adjustments',
            editor.toggleInspector,
            key: LogicalKeyboardKey.keyI, alt: true),
        Command(editor.histogramOpen ? 'Hide Histogram' : 'Show Histogram',
            when(photo, editor.toggleHistogram),
            key: LogicalKeyboardKey.keyH, alt: true),
      ],
      [
        for (final (i, p) in Panel.tabs.indexed)
          Command(p.title, () => editor.setPanel(p), key: digits[i], alt: true),
      ],
    ]),
    CommandMenu('Film', [
      [
        Command('New Grain Pattern',
            when(photo && editor.edit['stock'] != null, editor.newGrainPattern)),
      ],
    ]),
  ];
}

/// The shortcuts dialog's rows: each command with a shortcut, and holding Space.
List<(String, String)> shortcutRows(List<CommandMenu> menus) => [
      for (final menu in menus)
        for (final c in menu.commands)
          if (c.keys != null) (c.label, c.keys!),
      ('Show the original', 'Hold Space'),
    ];

/// Puts `menus` where the platform keeps commands: the menu bar on macOS, shortcuts elsewhere.
class CommandHost extends StatelessWidget {
  const CommandHost({super.key, required this.menus, required this.child});
  final List<CommandMenu> menus;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (HostWindow.usesMenuBar) return PlatformMenuBar(menus: _menuBar(), child: child);
    return CallbackShortcuts(
      bindings: {
        for (final menu in menus)
          for (final c in menu.commands)
            if (c.activator != null && c.run != null) c.activator!: c.run!,
      },
      child: child,
    );
  }

  List<PlatformMenuItem> _menuBar() => [
        const PlatformMenu(label: 'Fotufilm', menus: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ]),
        for (final menu in menus)
          PlatformMenu(label: menu.label, menus: [
            for (final group in menu.groups)
              PlatformMenuItemGroup(members: [for (final c in group) _menuItem(c)]),
          ]),
        const PlatformMenu(label: 'Window', menus: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
        ]),
      ];

  /// A command, or a submenu of them.
  static PlatformMenuItem _menuItem(Command c) {
    final submenu = c.submenu;
    if (submenu == null) {
      return PlatformMenuItem(label: c.label, shortcut: c.activator, onSelected: c.run);
    }
    return PlatformMenu(label: c.label, menus: [
      for (final group in submenu)
        if (group.isNotEmpty) PlatformMenuItemGroup(members: [for (final c in group) _menuItem(c)]),
    ]);
  }
}
