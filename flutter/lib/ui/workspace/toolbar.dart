// The editor's toolbar (web/src/editor/EditorToolbar.jsx), compact: 40 px in the panels' colour.
// The brand and Open on the left, zoom and the canvas tools in the middle, history, export and
// the panels on the right. On macOS it is the titlebar: its empty space drags the window.
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/host_window.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'import_menu.dart';

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
    final bar = Container(
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
            ImportMenu(editor: editor, onImage: onOpen),
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

/// Zoom, the canvas tools and the photograph's size.
class _ViewGroup extends StatelessWidget {
  const _ViewGroup({required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final doc = editor.active;
    final zoomed = doc != null && editor.zoomed;
    final megapixels = doc == null ? null : doc.width * doc.height / 1e6;
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
      Padding(
        padding: const EdgeInsets.only(left: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 46),
          child: Text(
            megapixels == null
                ? ''
                : '${doc!.raw ? 'RAW · ' : ''}${megapixels.toStringAsFixed(1)} MP',
            style: editorText(context, size: TextSizes.label, color: palette.muted),
          ),
        ),
      ),
    ]);
  }
}

/// The histogram, history, export, more and the inspector.
class _EditGroup extends StatelessWidget {
  const _EditGroup({required this.editor, required this.onExport, required this.onShortcuts});
  final EditorModel editor;
  final VoidCallback onExport, onShortcuts;

  @override
  Widget build(BuildContext context) {
    final doc = editor.active;
    const gap = SizedBox(width: Metrics.toolbarGap);
    return Row(children: [
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
            MenuItem(
              label: 'Import Scanned Negative…',
              icon: 'negative',
              onSelected: editor.negatives.canImport ? editor.negatives.chooseNegatives : null,
            ),
            MenuItem(
              label: 'Import Trichromatic Scan…',
              icon: 'negative',
              onSelected: editor.negatives.canMerge ? editor.negatives.chooseExposures : null,
            ),
            const MenuItem.divider(),
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
            // OptionsMenu.jsx's Tools.
            MenuItem(
              label: 'Crop',
              icon: 'crop',
              onSelected: doc != null && !editor.exporting ? () => editor.setPanel(Panel.crop) : null,
            ),
            MenuItem(
              label: 'Selective',
              icon: 'selective',
              onSelected: doc != null ? () => editor.setPanel(Panel.selective) : null,
            ),
            MenuItem(
              label: 'Inspect pipeline',
              icon: 'pipeline',
              onSelected: () => editor.setPanel(Panel.pipeline),
            ),
            const MenuItem.divider(),
            MenuItem(label: 'Keyboard shortcuts', icon: 'shortcuts', onSelected: onShortcuts),
          ]),
        ),
      ),
      gap,
      QuietButton(
        icon: 'inspector',
        tooltip: editor.inspectorOpen ? 'Hide adjustments' : 'Show adjustments',
        selected: editor.inspectorOpen,
        onPressed: editor.toggleInspector,
      ),
    ]);
  }
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
