// The Pipeline tool's panel (web/src/editor/PipelineInspector.jsx, styles/inspector.css
// `.pipeline-list`): the finished print, then each stage of the film's development, numbered, and
// whether a stage shows as its change from the one before.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import '../theme/theme.dart';
import 'controls.dart';

List<Widget> pipelinePanel(InspectorControls c) {
  final tool = c.editor.pipeline;
  return [
    Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 10),
        child: Text('Pipeline',
            style: editorText(context, size: TextSizes.heading, weight: FontWeight.w600)),
      ),
    ),
    if (tool.customised)
      const Padding(
        padding: EdgeInsets.only(top: 10),
        child: Note('Individual pipeline stages are available with the film’s default film, '
            'print and filter settings.'),
      ),
    Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _StageButton(
          label: 'Finished print',
          quiet: true,
          selected: tool.stage == null,
          onPressed: () => tool.setStage(null),
        ),
        for (var i = 0; i < tool.stages.length; i++) ...[
          const SizedBox(height: 3),
          _StageButton(
            number: '${i + 1}'.padLeft(2, '0'),
            label: tool.stageName(i),
            selected: tool.stage == i,
            onPressed: c.hasFilm ? () => tool.setStage(i) : null,
          ),
        ],
      ]),
    ),
    SwitchRow(
      label: 'Show stage difference',
      value: tool.difference,
      enabled: (tool.stage ?? 0) > 0,
      onChanged: tool.setDifference,
    ),
  ];
}

/// A row of the stage list: Spectrum's ActionButton, quiet for the finished print, with the
/// selected stage in the selection colour.
class _StageButton extends StatefulWidget {
  const _StageButton({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.number,
    this.quiet = false,
  });

  final String label;
  final String? number;
  final bool selected, quiet;
  final VoidCallback? onPressed;

  @override
  State<_StageButton> createState() => _StageButtonState();
}

class _StageButtonState extends State<_StageButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = widget.onPressed != null;
    final rest = widget.quiet ? null : palette.gray100;
    final fill = widget.selected
        ? palette.selected
        : pressed
            ? Color.alphaBlend(palette.pressed, rest ?? const Color(0x00000000))
            : hovered && enabled
                ? Color.alphaBlend(palette.hover, rest ?? const Color(0x00000000))
                : rest;
    final fg = widget.selected ? palette.accent : palette.text;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: tinted(
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(5)),
          child: Row(children: [
            if (widget.number != null) ...[
              Text(widget.number!,
                  style: editorText(context, size: TextSizes.caption, color: palette.muted)),
              const SizedBox(width: 14),
            ],
            Expanded(child: Text(widget.label, style: editorText(context, color: fg))),
          ]),
        ),
      ),
    );
  }
}
