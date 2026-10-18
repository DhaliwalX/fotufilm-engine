// The inspector, compact: "Darkroom" and its help, the four panels as a segmented control, and the
// chosen panel's sections. Collapsed, it is a rail of the panels' buttons.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/panel_layout.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import '../workspace/panel_layout.dart';
import 'controls.dart';
import 'panels.dart';

class EditorInspector extends StatefulWidget {
  const EditorInspector({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<EditorInspector> createState() => _EditorInspectorState();
}

class _EditorInspectorState extends State<EditorInspector> {
  // Each panel keeps its own place.
  final _scrolls = {for (final p in Panel.values) p: ScrollController()};

  static const _help = {
    Panel.film: 'Load a stock and choose its format and character.',
    Panel.light: 'Adjust the light and filters, then refine the colour grade.',
    Panel.develop: 'Develop the film, then shape its grain and colour separation.',
    Panel.print: 'Choose a print or scan, set its viewing light, and export.',
    Panel.roll: 'Balance every frame of a roll of negatives on the roll’s colour.',
    Panel.selective: 'Adjust a selected colour, area, or subject.',
    Panel.crop: 'Frame and straighten the finished photograph.',
    Panel.pipeline: 'Inspect each stage of the film development pipeline.',
  };

  @override
  void dispose() {
    for (final s in _scrolls.values) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final scroll = _scrolls[editor.panel]!;
    return ColoredBox(
      color: Palette.of(context).panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: Metrics.headingPadding,
          child: Row(children: [
            Text(
                switch (editor.panel) {
                  Panel.crop => 'Crop',
                  Panel.selective => 'Selective',
                  _ => 'Darkroom',
                },
                style: editorText(context, size: TextSizes.heading, weight: FontWeight.w700)),
            const SizedBox(width: 2),
            HelpButton(detail: _help[editor.panel], size: 16),
            if (editor.panel == Panel.crop || editor.panel == Panel.selective) ...[
              const SizedBox(width: 6),
              Text('Canvas tool',
                  style: editorText(context,
                      size: TextSizes.label, color: Palette.of(context).muted)),
            ],
            const Spacer(),
            PanelDismissButton(editor: editor, side: PanelSide.inspector),
          ]),
        ),
        Padding(
          padding: Metrics.tabsPadding,
          child: SegmentedControl<Panel>(
            items: [for (final p in editor.inspectorTabs) (p, p.title)],
            // A canvas tool takes the inspector over; no tab is chosen while it does.
            selected: editor.inspectorTabs.contains(editor.panel) ? editor.panel : null,
            onChanged: editor.setPanel,
          ),
        ),
        Expanded(
          child: ThinScroll(
            controller: scroll,
            child: SingleChildScrollView(
              controller: scroll,
              padding: Metrics.inspectorPadding,
              // The controls wait for a photograph; the panel still scrolls.
              child: AbsorbPointer(
                absorbing: editor.active == null || editor.exporting,
                child: Column(
                  // A new panel or film is a new set of controls, not the old ones updated.
                  key: ValueKey('${editor.panel}:${editor.edit['stock']}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: panelSections(editor.panel, InspectorControls(editor)),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The collapsed inspector's rail of panel buttons.
class InspectorRail extends StatelessWidget {
  const InspectorRail({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => Container(
        color: Palette.of(context).panel,
        padding: const EdgeInsets.only(top: 6),
        child: Column(children: [
          for (final p in editor.inspectorTabs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: QuietButton(
                icon: p.icon,
                tooltip: p.title,
                selected: editor.panel == p,
                onPressed: () => editor.setPanel(p),
              ),
            ),
        ]),
      );
}
