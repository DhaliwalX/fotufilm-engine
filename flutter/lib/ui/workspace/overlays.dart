// What the viewer shows over or instead of the photograph: the empty canvas, the Original badge,
// the status pill, the error banner and the drop target. Each places itself in the viewer's Stack.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import '../theme/theme.dart';

class EmptyCanvas extends StatelessWidget {
  const EmptyCanvas({super.key, required this.onOpen, required this.ready, this.error});
  final VoidCallback onOpen;
  final bool ready;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('The engine could not start. $error',
              textAlign: TextAlign.center, style: editorText(context, color: palette.muted)),
        ),
      );
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        PillButton('Open image or video',
            variant: ButtonVariant.accent, onPressed: ready ? onOpen : null),
        const SizedBox(height: 8),
        Text(ready ? 'or drop files here' : 'Loading films…',
            style: editorText(context, color: palette.muted)),
      ]),
    );
  }
}

class OriginalBadge extends StatelessWidget {
  const OriginalBadge({super.key});

  @override
  Widget build(BuildContext context) => Positioned(
        bottom: 12,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xCC25272C),
              border: Border.all(color: const Color(0x35FFFFFF)),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text('Original',
                style: editorText(context, size: TextSizes.label, color: const Color(0xFFFFFFFF))),
          ),
        ),
      );
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, this.onCancel});
  final String text;
  /// Shows Cancel (the import pill's, EditorViewer.jsx).
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Positioned(
        top: 10,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: EdgeInsets.fromLTRB(10, onCancel == null ? 6 : 2, onCancel == null ? 10 : 2,
                onCancel == null ? 6 : 2),
            decoration: BoxDecoration(
              color: Palette.of(context).panel,
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 2)),
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(text, style: editorText(context)),
              if (onCancel != null) ...[
                const SizedBox(width: 6),
                QuietButton(label: 'Cancel', size: 24, onPressed: onCancel),
              ],
            ]),
          ),
        ),
      );
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.text, required this.onClose, this.onRetry});
  final String text;
  final VoidCallback onClose;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final dark = Palette.of(context).dark;
    final fg = dark ? const Color(0xFFF0C6B9) : const Color(0xFF733A2B);
    return Positioned(
      top: 10,
      left: 10,
      right: 10,
      child: Appear(
        key: ValueKey(text),
        rise: -6,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF402D2A) : const Color(0xFFFFF1ED),
            border: Border.all(color: dark ? const Color(0xFF765045) : const Color(0xFFE7C0B4)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Expanded(
              child: Text(text,
                  style: editorText(context, size: TextSizes.label, color: fg, height: 1.45)),
            ),
            if (onRetry != null) QuietButton(label: 'Retry', size: 24, onPressed: onRetry),
            QuietButton(icon: 'close', tooltip: 'Dismiss', onPressed: onClose, iconSize: 15),
          ]),
        ),
      ),
    );
  }
}

class DropOverlay extends StatelessWidget {
  const DropOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Positioned.fill(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: CustomPaint(
          painter: _DashedBorder(palette.accent),
          child: Container(
            decoration: BoxDecoration(
              color: palette.dark ? const Color(0xED253754) : const Color(0xEFE1E9F5),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text('Drop images to open', style: editorText(context, size: TextSizes.dialog)),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}
