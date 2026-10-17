// The editor's commands, listed once. On macOS they are the menu bar with ⌘ shortcuts; on Linux
// and Windows the same shortcuts answer with Ctrl. The shortcuts dialog lists them from here too.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/app_dialogs.dart';
import '../model/editor.dart';
import '../model/presets.dart' show pasteTitle;
import '../ui/workspace/editing_dialogs.dart';
import '../ui/workspace/film_pack_notice.dart';
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
    // The app menu's own commands (cef/src/platform/mac/main_menu.mm), around the system's.
    CommandMenu(appMenu, [
      [Command('Check for Updates…', when(editor.updates.available, editor.updates.check))],
      [
        Command('Settings…', () => editor.dialogs.request(AppDialog.settings),
            key: LogicalKeyboardKey.comma),
      ],
    ]),
    CommandMenu('File', [
      [
        Command('Open…', when(editor.ready, open), key: LogicalKeyboardKey.keyO),
        Command('Import Scanned Negative…',
            when(editor.negatives.canImport, editor.negatives.chooseNegatives)),
        Command('Import Trichromatic Scan…',
            when(editor.negatives.canMerge, editor.negatives.chooseExposures)),
        Command('Close Photo', when(photo, () => editor.closeDocument(editor.activeIndex)),
            key: LogicalKeyboardKey.keyW),
      ],
      [
        Command('Import Film Pack…',
            when(editor.filmPacks.available && !editor.exporting, () => chooseFilmPacks(editor)),
            key: LogicalKeyboardKey.keyI, shift: true),
      ],
      [
        Command('Export…', when(photo && !editor.exporting, export), key: LogicalKeyboardKey.keyE),
        Command('Use Last Export Settings',
            when(photo && !editor.exporting && editor.exporter.last != null,
                editor.exporter.exportWithLast)),
      ],
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
        // Opens Selective and samples the next click (useNativeCommands.js `sampleSelection`).
        Command('Sample a Selection',
            when(editor.selective.canSample, editor.selective.startSampling),
            key: LogicalKeyboardKey.keyS, shift: true),
      ],
      [
        Command('Copy Photo', when(editor.exporter.canCopy && !editor.exporting,
            editor.exporter.copyPhoto), key: LogicalKeyboardKey.keyC, shift: true),
      ],
      // Copy Settings, Paste Settings and presets (editing_dialogs.dart).
      if (context != null)
        [
          Command('Copy Settings…', when(photo, () => showCopySettingsDialog(context, editor)),
              key: LogicalKeyboardKey.keyC, alt: true),
          Command(pasteTitle(editor.selection.chosen.length),
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
      // A movie's Play, which reads Pause while it plays (useNativeCommands.js `play`).
      [
        Command(editor.video.playing ? 'Pause' : 'Play',
            when(editor.video.canPlay, editor.video.toggle)),
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
        Command(editor.negatives.showNegative ? 'Hide Negative' : 'Show Negative',
            when(editor.negatives.canShowNegativeNow, editor.negatives.toggleShowNegative),
            key: LogicalKeyboardKey.keyN, alt: true),
      ],
      [
        for (final (i, p) in Panel.tabs.indexed)
          Command(p.title, () => editor.setPanel(p), key: digits[i], alt: true),
        Command('Crop', when(photo, () => editor.setPanel(Panel.crop))),
      ],
    ]),
    CommandMenu('Film', [
      [
        Command('New Grain Pattern',
            when(photo && editor.edit['stock'] != null, editor.newGrainPattern)),
      ],
    ]),
    // Two items per editor, Install reading Reinstall once the plug-in is there.
    if (editor.plugins.available)
      CommandMenu('Plugins', [
        for (final p in editor.plugins.catalogue)
          [
            Command(
              '${_pluginInstalled(editor, p) ? 'Reinstall' : 'Install'} ${p['name']} Plug-in…',
              when(editor.plugins.busy == null && !editor.exporting, () {
                editor.dialogs.request(AppDialog.plugins);
                editor.plugins.install(p['id'] as String);
              }),
            ),
            Command('Show ${p['name']} Plug-in in Finder',
                when(_pluginInstalled(editor, p), () => editor.plugins.reveal(p['id'] as String))),
          ],
      ]),
  ];
}

/// The menu whose commands join the system's app menu on macOS.
const appMenu = 'Fotufilm';

bool _pluginInstalled(EditorModel editor, Json plugin) {
  final state = editor.plugins.status(plugin['id'] as String)?['state'];
  return state != null && state != 'notInstalled' && state != 'notBundled';
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

  static PlatformMenuItemGroup _group(List<Command> group) =>
      PlatformMenuItemGroup(members: [for (final c in group) _menuItem(c)]);

  List<PlatformMenuItem> _menuBar() => [
        PlatformMenu(label: 'Fotufilm', menus: [
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          for (final menu in menus)
            if (menu.label == appMenu) ...menu.groups.map(_group),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ]),
        for (final menu in menus)
          if (menu.label != appMenu)
            PlatformMenu(label: menu.label, menus: [for (final group in menu.groups) _group(group)]),
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
