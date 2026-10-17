// The editor's toolbar (web/src/editor/EditorToolbar.jsx), compact: 40 px in the panels' colour.
// The brand, the library and Add media on the left (FileToolbar.jsx), zoom and the canvas tools in
// the middle (ViewToolbar.jsx), the histogram, history, export, More and the inspector on the
// right (EditToolbar.jsx, OptionsMenu.jsx). On macOS it is the titlebar: its empty space drags
// the window.
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/commands.dart';
import '../../app/editor_shortcuts.dart' show shortcutLabel;
import '../../app/host_window.dart';
import '../../model/app_dialogs.dart';
import '../../model/editor.dart';
import '../../model/presets.dart' show pasteTitle;
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'film_pack_notice.dart';
import 'import_menu.dart';
import 'support_dialog.dart';
import 'viewer_status.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({super.key, required this.commands});

  final EditorCommands commands;
  EditorModel get editor => commands.editor;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final titlebar = HostWindow.toolbarIsTitlebar;
    final bar = editor.layout.compact ? _compact(palette, titlebar) : Container(
      height: Metrics.toolbarHeight,
      color: palette.panel,
      padding: const EdgeInsets.symmetric(horizontal: Metrics.toolbarPadding),
      child: Row(children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: Metrics.toolbarLeadingWidth),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            // The traffic lights sit in the toolbar's leading inset, as in the CEF app.
            if (titlebar) const SizedBox(width: Metrics.trafficLightInset),
            const SizedBox(width: 7),
            const FotufilmBrand(),
            const SizedBox(width: 8),
            _LibraryButton(editor: editor),
            ImportMenu(editor: editor, onImage: commands.actions.open),
          ]),
        ),
        // The library hides the photograph's controls (photo-library.css).
        Expanded(child: _whileEditing(_ViewGroup(editor: editor))),
        _whileEditing(_EditGroup(commands: commands)),
      ]),
    );
    if (!titlebar) return bar;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => HostWindow.startDrag(),
      onDoubleTap: HostWindow.zoom,
      child: bar,
    );
  }

  Widget _whileEditing(Widget child) => Visibility(
      visible: !editor.library.open,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: child);
}

/// The compact layout's toolbar (phone-layout.css): the brand, the library and Add media on one
/// row, and the edit buttons spread across the next; zoom gives way.
extension on EditorToolbar {
  Widget _compact(Palette palette, bool titlebar) => Container(
        color: palette.panel,
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: Metrics.compactToolbarRow,
            child: Row(children: [
              if (titlebar) const SizedBox(width: Metrics.trafficLightInset),
              const FotufilmBrand(),
              const Spacer(),
              _LibraryButton(editor: editor, size: Metrics.compactTouch),
              const SizedBox(width: 8),
              ImportMenu(editor: editor, onImage: commands.actions.open, size: Metrics.compactTouch),
            ]),
          ),
          SizedBox(
            height: Metrics.compactToolbarRow,
            child: _EditGroup(commands: commands, compact: true),
          ),
        ]),
      );
}

/// The library's toggle (FileToolbar.jsx).
class _LibraryButton extends StatelessWidget {
  const _LibraryButton({required this.editor, this.size = Metrics.control});
  final EditorModel editor;
  final double size;

  @override
  Widget build(BuildContext context) => QuietButton(
        icon: 'library',
        tooltip: 'Library (L)',
        selected: editor.library.open,
        size: size,
        onPressed: editor.exporting ? null : editor.library.toggle,
      );
}

/// Zoom, the canvas tools and the photograph's size (ViewToolbar.jsx).
class _ViewGroup extends StatelessWidget {
  const _ViewGroup({required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final doc = editor.active;
    final photo = doc != null;
    // Where the view stands between fit and the largest zoom (photo-view.js `zoomReach`).
    final fit = !editor.zoomed;
    final max = editor.zoomed && editor.scale >= ViewState.maxZoom * .999;
    final cropMode = editor.crop.showing;
    // Each tool opens in the inspector (useEditingActions.js `setInspector`).
    void open(Panel panel) => editor.layout.choosePanel(panel);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      QuietButton(
          icon: 'minus',
          tooltip: 'Zoom out',
          onPressed: !photo || fit || cropMode ? null : editor.zoomOut),
      SizedBox(
        width: 40,
        child: Text(fit ? 'Fit' : '${(editor.scale * 100).round()}%',
            textAlign: TextAlign.center,
            style: editorText(context,
                color: doc == null ? palette.text.withValues(alpha: .4) : palette.text)),
      ),
      QuietButton(
          icon: 'plus',
          tooltip: 'Zoom in',
          onPressed: !photo || max || cropMode ? null : editor.zoomIn),
      const SizedBox(width: Metrics.toolbarGap),
      QuietButton(
          icon: 'fit',
          tooltip: 'Zoom to fit (0)',
          onPressed: !photo || fit ? null : () => editor.setZoom(null)),
      const SizedBox(width: Metrics.toolbarGap),
      QuietButton(
        icon: 'selective',
        tooltip: 'Selective',
        selected: editor.panel == Panel.selective && editor.inspectorOpen,
        onPressed: !photo || editor.exporting ? null : () => open(Panel.selective),
      ),
      const SizedBox(width: Metrics.toolbarGap),
      QuietButton(
        icon: 'crop',
        tooltip: 'Crop',
        selected: editor.panel == Panel.crop && editor.inspectorOpen,
        onPressed: !photo || editor.exporting ? null : () => open(Panel.crop),
      ),
      // A middling window gives the readout's room to the tools (responsive.css).
      if (!_crowded(editor.layout.window)) PixelReadout(doc: doc),
    ]);
  }
}

bool _crowded(double? window) => window != null && window > 833 && window < 1010;

/// The histogram, history, reset, export, More and the inspector (EditToolbar.jsx).
class _EditGroup extends StatelessWidget {
  const _EditGroup({required this.commands, this.compact = false});
  final EditorCommands commands;

  /// Spread across the compact toolbar's second row, at touch size.
  final bool compact;

  EditorModel get editor => commands.editor;

  @override
  Widget build(BuildContext context) {
    final doc = editor.active;
    final exporting = editor.exporting;
    final history = doc?.history;
    const gap = SizedBox(width: Metrics.toolbarGap);
    final row = Row(children: [
      QuietButton(
        icon: 'histogram',
        tooltip: 'Histogram (H)',
        selected: editor.histogramOpen,
        onPressed: doc != null ? editor.toggleHistogram : null,
      ),
      Container(
        width: 1,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        color: Palette.of(context).border,
      ),
      // What Undo and Redo will change, as the Edit menu names it.
      QuietButton(
          icon: 'undo',
          tooltip: '${editor.history.undo} (${shortcutLabel('⌘Z')})',
          onPressed: (history?.past.isNotEmpty ?? false) && !exporting ? editor.undo : null),
      gap,
      QuietButton(
          icon: 'redo',
          tooltip: '${editor.history.redo} (${shortcutLabel('⇧⌘Z')})',
          onPressed: (history?.future.isNotEmpty ?? false) && !exporting ? editor.redo : null),
      gap,
      QuietButton(
          icon: 'reset',
          tooltip: 'Reset all edits',
          onPressed: doc != null && !exporting ? editor.resetEdit : null),
      gap,
      QuietButton(
          icon: 'export',
          tooltip: 'Export (${shortcutLabel('⌘E')})',
          onPressed: doc != null && editor.stocks.isNotEmpty && !exporting
              ? commands.actions.export
              : null),
      gap,
      Builder(
        key: moreOptionsKey,
        builder: (anchor) => QuietButton(
          icon: 'more',
          tooltip: 'More options',
          onPressed: () => showMoreOptions(anchor, commands),
        ),
      ),
      gap,
      QuietButton(
        icon: 'inspector',
        tooltip: 'Toggle adjustments',
        selected: editor.inspectorOpen,
        onPressed: editor.layout.toggleInspector,
      ),
    ]);
    if (!compact) return row;
    // The compact row: no divider, the buttons spread at touch size.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final child in row.children)
          if (child is QuietButton)
            _touch(child)
          else if (child is Builder)
            Builder(builder: (anchor) => _touch(child.builder(anchor) as QuietButton)),
      ],
    );
  }

  static Widget _touch(QuietButton b) => QuietButton(
        icon: b.icon,
        tooltip: b.tooltip,
        selected: b.selected,
        onPressed: b.onPressed,
        size: Metrics.compactTouch,
      );
}

/// The More button, for the driver to open its menu.
final moreOptionsKey = GlobalKey(debugLabel: 'moreOptions');

/// The More menu (OptionsMenu.jsx): its sections in order, each closed by a divider.
void showMoreOptions(BuildContext anchor, EditorCommands commands) {
  final editor = commands.editor;
  final exporting = editor.exporting;
  final doc = editor.active;
  final noPhoto = doc == null || exporting;
  // Fotufilm Flutter opens no video, so only a photo or an export greys the image-only tools.
  final imageOnlyDisabled = noPhoto;
  final auto = editor.auto;
  final presets = editor.presets;
  final steps = editor.history.timeline;
  void open(Panel panel) => editor.layout.choosePanel(panel);
  final sections = <List<MenuItem>>[
    [
      MenuItem(
        label: 'Import Scanned Negative…',
        icon: 'negative',
        onSelected: editor.negatives.canImport ? editor.negatives.chooseNegatives : null,
      ),
      if (editor.engine?.opensPaths ?? true)
        MenuItem(
          label: 'Import Trichromatic Scan…',
          icon: 'negative',
          onSelected: editor.negatives.canMerge ? editor.negatives.chooseExposures : null,
        ),
      if (editor.filmPacks.available)
        MenuItem(
          label: 'Import Film Pack…',
          icon: 'film',
          onSelected: exporting ? null : () => chooseFilmPacks(editor),
        ),
    ],
    // Automatic adjustments: a mode, ticked while it is on.
    [
      MenuItem(
        label: auto.busy
            ? 'Cancel Auto Adjust'
            : editor.catalogue.control('autoAdjustment')['title'] as String,
        icon: auto.busy ? 'close' : 'autoAdjust',
        selection: MenuSelection.multiple,
        checked: auto.active,
        onSelected: auto.available ? auto.toggle : null,
      ),
    ],
    // Every step of the shown photograph's history, the one standing ticked.
    [
      MenuItem(
        label: 'Edit History',
        icon: 'undo',
        submenu: noPhoto
            ? const []
            : [
                for (final (i, title) in steps.titles.indexed)
                  MenuItem(
                    label: title,
                    selection: MenuSelection.single,
                    checked: i == steps.index,
                    onSelected: () => editor.history.goTo(i),
                  ),
              ],
      ),
    ],
    // Paste Settings and presets go onto every photo chosen in the strip.
    [
      MenuItem(
        label: 'Copy Settings…',
        icon: 'copySettings',
        description: shortcutLabel('⌥⌘C'),
        onSelected: noPhoto ? null : commands.actions.copySettings,
      ),
      MenuItem(
        label: pasteTitle(editor.selection.chosen.length),
        icon: 'pasteSettings',
        description: shortcutLabel('⌥⌘V'),
        onSelected: noPhoto || presets.copied == null ? null : presets.paste,
      ),
      MenuItem(label: 'Presets', icon: 'presets', submenu: [
        for (final preset in presets.list)
          MenuItem(
              label: preset.name,
              onSelected: noPhoto ? null : () => presets.applyPreset(preset.id)),
        if (presets.list.isNotEmpty) const MenuItem.divider(),
        MenuItem(label: 'Save Preset…', onSelected: noPhoto ? null : commands.actions.savePreset),
        MenuItem(
            label: 'Manage Presets…',
            onSelected: presets.list.isEmpty ? null : commands.actions.managePresets),
        MenuItem(label: 'Import Looks…', onSelected: exporting ? null : commands.actions.importLooks),
      ]),
    ],
    [
      MenuItem(
          label: 'Save edits…',
          icon: 'saveEdits',
          onSelected: noPhoto ? null : editor.keptEdits.saveFile),
      MenuItem(
          label: 'Load edits…',
          icon: 'loadEdits',
          onSelected: noPhoto ? null : editor.keptEdits.loadFile),
    ],
    [
      MenuItem(
        label: 'Selective',
        icon: 'selective',
        onSelected: imageOnlyDisabled ? null : () => open(Panel.selective),
      ),
      MenuItem(
        label: 'Crop',
        icon: 'crop',
        onSelected: imageOnlyDisabled ? null : () => open(Panel.crop),
      ),
      MenuItem(label: 'Inspect pipeline', icon: 'pipeline', onSelected: () => open(Panel.pipeline)),
    ],
    [
      MenuItem(
        label: 'Settings…',
        icon: 'adjustments',
        onSelected: () => editor.dialogs.request(AppDialog.settings),
      ),
      if (editor.plugins.available)
        MenuItem(
          label: 'Plug-ins…',
          icon: 'export',
          onSelected: exporting ? null : () => editor.dialogs.request(AppDialog.plugins),
        ),
      MenuItem(
        label: 'Keyboard shortcuts',
        icon: 'shortcuts',
        onSelected: () => editor.dialogs.request(AppDialog.shortcuts),
      ),
      MenuItem(
        label: 'Browser support',
        icon: 'help',
        onSelected: () => editor.dialogs.request(AppDialog.support),
      ),
    ],
    legalMenuItems(editor.catalogue),
  ];
  showMenu(anchor, alignEnd: true, width: 240, [
    for (final (i, section) in sections.where((s) => s.isNotEmpty).indexed) ...[
      if (i > 0) const MenuItem.divider(),
      ...section,
    ],
  ]);
}

/// The app's icon and wordmark (web/src/editor/FotufilmBrand.jsx, compact).
class FotufilmBrand extends StatelessWidget {
  const FotufilmBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.asset('assets/generated/app-icon.png',
            width: 24, height: 24, filterQuality: FilterQuality.medium),
      ),
      const SizedBox(width: 8),
      SvgPicture.asset(
        'assets/generated/fotufilm-wordmark.svg',
        width: 80,
        height: 16,
        colorFilter: ColorFilter.mode(
            palette.dark ? const Color(0xFFFFFFFF) : const Color(0xD9000000), BlendMode.srcIn),
      ),
    ]);
  }
}
