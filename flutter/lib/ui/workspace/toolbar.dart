// The editor's toolbar (web/src/editor/EditorToolbar.jsx), compact: 40 px in the panels' colour.
// The brand and Open on the left, zoom and the canvas tools in the middle, history, export and
// the panels on the right. On macOS it is the titlebar: its empty space drags the window.
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/host_window.dart';
import '../../model/app_dialogs.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'film_pack_notice.dart';
import 'support_dialog.dart';
import 'viewer_status.dart';

class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.editor,
    required this.onOpen,
    required this.onExport,
    required this.onShortcuts,
  });

  final EditorModel editor;
  final VoidCallback onOpen, onExport, onShortcuts;

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
            const QuietButton(icon: 'library', tooltip: 'Photo library'),
            QuietButton(icon: 'plus', tooltip: 'Open image or video', onPressed: onOpen),
          ]),
        ),
        Expanded(child: _ViewGroup(editor: editor)),
        _EditGroup(editor: editor, onExport: onExport, onShortcuts: onShortcuts),
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
}

/// The compact layout's toolbar (phone-layout.css): the brand, the library and Open on one row,
/// and the edit buttons spread across the next; zoom gives way.
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
              const QuietButton(
                  icon: 'library', tooltip: 'Photo library', size: Metrics.compactTouch),
              const SizedBox(width: 8),
              QuietButton(
                  icon: 'plus',
                  tooltip: 'Open image or video',
                  size: Metrics.compactTouch,
                  onPressed: onOpen),
            ]),
          ),
          SizedBox(
            height: Metrics.compactToolbarRow,
            child: _EditGroup(
                editor: editor, onExport: onExport, onShortcuts: onShortcuts, compact: true),
          ),
        ]),
      );
}

/// Zoom, the canvas tools and the photograph's size.
class _ViewGroup extends StatelessWidget {
  const _ViewGroup({required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final doc = editor.active;
    final zoomed = doc != null && editor.zoomed;
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      QuietButton(icon: 'minus', tooltip: 'Zoom out', onPressed: zoomed ? editor.zoomOut : null),
      SizedBox(
        width: 40,
        child: Text(zoomed ? '${(editor.scale * 100).round()}%' : 'Fit',
            textAlign: TextAlign.center,
            style: editorText(context,
                color: doc == null ? palette.text.withValues(alpha: .4) : palette.text)),
      ),
      QuietButton(icon: 'plus', tooltip: 'Zoom in', onPressed: doc != null ? editor.zoomIn : null),
      const SizedBox(width: Metrics.toolbarGap),
      QuietButton(
          icon: 'fit', tooltip: 'Zoom to fit', onPressed: zoomed ? () => editor.setZoom(null) : null),
      const SizedBox(width: Metrics.toolbarGap),
      QuietButton(
        icon: 'selective',
        tooltip: 'Selective',
        selected: editor.panel == Panel.selective,
        onPressed: doc != null ? () => editor.toggleTool(Panel.selective) : null,
      ),
      const SizedBox(width: Metrics.toolbarGap),
      QuietButton(
        icon: 'crop',
        tooltip: 'Crop',
        selected: editor.panel == Panel.crop,
        onPressed: doc != null ? () => editor.toggleTool(Panel.crop) : null,
      ),
      // A middling window gives the readout's room to the tools (responsive.css).
      if (!_crowded(editor.layout.window)) PixelReadout(doc: doc),
    ]);
  }
}

bool _crowded(double? window) => window != null && window > 833 && window < 1010;

/// The histogram, history, export, more and the inspector.
class _EditGroup extends StatelessWidget {
  const _EditGroup(
      {required this.editor,
      required this.onExport,
      required this.onShortcuts,
      this.compact = false});
  final EditorModel editor;
  final VoidCallback onExport, onShortcuts;

  /// Spread across the compact toolbar's second row, at touch size.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final doc = editor.active;
    const gap = SizedBox(width: Metrics.toolbarGap);
    final row = Row(children: [
      QuietButton(
        icon: 'histogram',
        tooltip: editor.histogramOpen ? 'Hide histogram' : 'Show histogram',
        selected: editor.histogramOpen,
        onPressed: doc != null ? editor.toggleHistogram : null,
      ),
      Container(
        width: 1,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        color: Palette.of(context).border,
      ),
      QuietButton(icon: 'undo', tooltip: 'Undo', onPressed: editor.canUndo ? editor.undo : null),
      gap,
      QuietButton(icon: 'redo', tooltip: 'Redo', onPressed: editor.canRedo ? editor.redo : null),
      gap,
      QuietButton(
          icon: 'reset', tooltip: 'Reset all edits', onPressed: editor.edited ? editor.resetEdit : null),
      gap,
      QuietButton(
          icon: 'export',
          tooltip: 'Export',
          onPressed: doc != null && !editor.exporting ? onExport : null),
      gap,
      Builder(
        builder: (anchor) => QuietButton(
          icon: 'more',
          tooltip: 'More options',
          onPressed: () => showMenu(anchor, alignEnd: true, width: 240, [
            if (editor.filmPacks.available) ...[
              MenuItem(
                label: 'Import Film Pack…',
                icon: 'film',
                onSelected: editor.exporting ? null : () => chooseFilmPacks(editor),
              ),
              const MenuItem.divider(),
            ],
            MenuItem(
              label: 'Auto Adjust',
              icon: 'autoAdjust',
              checked: editor.autoAdjust,
              onSelected: editor.toggleAutoAdjust,
            ),
            const MenuItem.divider(),
            MenuItem(
              label: 'New Grain Pattern',
              icon: 'refresh',
              onSelected:
                  doc != null && editor.edit['stock'] != null ? editor.newGrainPattern : null,
            ),
            const MenuItem.divider(),
            MenuItem(
              label: 'Settings…',
              icon: 'adjustments',
              onSelected: () => editor.dialogs.request(AppDialog.settings),
            ),
            if (editor.plugins.available)
              MenuItem(
                label: 'Plug-ins…',
                icon: 'export',
                onSelected:
                    editor.exporting ? null : () => editor.dialogs.request(AppDialog.plugins),
              ),
            MenuItem(label: 'Keyboard shortcuts', icon: 'shortcuts', onSelected: onShortcuts),
            MenuItem(
              label: 'Browser support',
              icon: 'help',
              onSelected: () => editor.dialogs.request(AppDialog.support),
            ),
            const MenuItem.divider(),
            ...legalMenuItems(editor.catalogue),
          ]),
        ),
      ),
      gap,
      QuietButton(
        icon: 'inspector',
        tooltip: editor.inspectorOpen ? 'Hide adjustments' : 'Show adjustments',
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
