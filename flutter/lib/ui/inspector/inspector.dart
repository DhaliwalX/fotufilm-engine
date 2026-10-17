// The inspector (web/src/editor/EditorInspector.jsx), compact: "Darkroom" and its help, the four
// panels as a segmented control, and the chosen panel's sections. Collapsed, it is a rail of the
// panels' buttons.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'controls.dart';
import 'develop_panel.dart';
import 'expose_panel.dart';
import 'film_panel.dart';
import 'print_panel.dart';

class EditorInspector extends StatefulWidget {
  const EditorInspector({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<EditorInspector> createState() => _EditorInspectorState();
}

class _EditorInspectorState extends State<EditorInspector> {
  // Each panel keeps its own place, as InspectorPanel.jsx does.
  final _scrolls = {for (final p in Panel.values) p: ScrollController()};

  static const _help = {
    Panel.film: 'Choose the film’s format and condition, and how its halation spreads.',
    Panel.light: 'Expose the scene: light, source illuminant, white balance, colour and grade.',
    Panel.develop: 'Develop the negative: push or pull, bleach bypass, grain and colour separation.',
    Panel.print: 'Print or scan the developed film, onto paper or for the screen.',
  };

  static List<Widget> _sections(Panel panel, InspectorControls controls) => switch (panel) {
        Panel.film => filmPanel(controls),
        Panel.light => exposePanel(controls),
        Panel.develop => developPanel(controls),
        Panel.print => printPanel(controls),
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
            Text('Darkroom',
                style: editorText(context, size: TextSizes.heading, weight: FontWeight.w700)),
            const SizedBox(width: 2),
            HelpButton(detail: _help[editor.panel], size: 16),
          ]),
        ),
        Padding(
          padding: Metrics.tabsPadding,
          child: SegmentedControl<Panel>(
            items: [for (final p in Panel.values) (p, p.title)],
            selected: editor.panel,
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
                  children: _sections(editor.panel, InspectorControls(editor)),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The collapsed inspector's rail of panel buttons (InspectorRail.jsx).
class InspectorRail extends StatelessWidget {
  const InspectorRail({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => Container(
        color: Palette.of(context).panel,
        padding: const EdgeInsets.only(top: 6),
        child: Column(children: [
          for (final p in Panel.values)
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
