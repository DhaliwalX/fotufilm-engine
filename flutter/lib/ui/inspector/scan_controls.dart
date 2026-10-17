// The Spectrum controls the negative's and the roll's panels use beyond the kit: an ActionButton
// (filled, or quiet) and a ToggleButton at size S, stretched across the section as the
// control stack stretches them, and a ProgressBar with its label.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import '../theme/theme.dart';

class ScanButton extends StatefulWidget {
  const ScanButton(this.label,
      {super.key, this.onPressed, this.quiet = false, this.selected = false});
  final String label;
  final VoidCallback? onPressed;

  /// Transparent at rest, as Spectrum's `isQuiet`.
  final bool quiet;

  /// A ToggleButton that is on.
  final bool selected;

  @override
  State<ScanButton> createState() => _ScanButtonState();
}

class _ScanButtonState extends State<ScanButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = widget.onPressed != null;
    final rest = widget.quiet ? null : palette.gray100;
    final bg = widget.selected
        ? palette.gray800
        : pressed && enabled
            ? Color.alphaBlend(palette.pressed, rest ?? const Color(0x00000000))
            : hovered && enabled
                ? Color.alphaBlend(palette.hover, rest ?? const Color(0x00000000))
                : rest;
    return tinted(
      onTap: widget.onPressed,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: Container(
          height: Metrics.control,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Metrics.radius)),
          child: Text(widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: editorText(context,
                  weight: FontWeight.w500,
                  color: widget.selected ? palette.onSelected : palette.text)),
        ),
      ),
    );
  }
}

/// Spectrum's ProgressBar at size S: its label and percentage over a thin track.
class ScanProgress extends StatelessWidget {
  const ScanProgress({super.key, required this.label, required this.value});
  final String label;

  /// 0 to 1.
  final double value;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final style = editorText(context, size: TextSizes.label);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(label, style: style)),
        Text('${(value * 100).round()}%', style: style),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: palette.gray300),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0, 1),
              child: ColoredBox(color: palette.gray800),
            ),
          ]),
        ),
      ),
    ]);
  }
}

/// A muted hint under a section's controls (`.inspector-hint`).
class ScanHint extends StatelessWidget {
  const ScanHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text,
            style: editorText(context,
                size: TextSizes.label, color: Palette.of(context).muted, height: 1.6)),
      );
}
