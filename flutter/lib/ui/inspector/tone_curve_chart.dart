// The Output panel's tone curve: how the edit's film, output medium and grade carry each input
// tone, per channel, over the photograph's own tones on the same input axis.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/histogram.dart' show smoothHistogram;
import '../../model/tone_curve.dart';
import '../theme/theme.dart';
import '../workspace/histogram_panel.dart' show histogramColors;

class ToneCurveChart extends StatelessWidget {
  const ToneCurveChart({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.toneCurve,
        builder: (context, _) {
          final curve = (editor.toneCurve..follow()).curve;
          if (curve == null) return const SizedBox.shrink();
          final palette = Palette.of(context);
          return Semantics(
            label: 'Tone curve',
            value: _description(curve),
            child: AspectRatio(
              aspectRatio: 280 / 168,
              child: CustomPaint(
                painter: _ToneCurvePainter(
                  curve: curve,
                  palette: palette,
                  colors: histogramColors(palette.dark),
                  labelStyle: editorText(context, size: 8, color: palette.muted),
                ),
              ),
            ),
          );
        },
      );

  /// Where black and white land, for a reader that cannot see the chart.
  static String _description(ToneCurveData curve) {
    String code(double v) => '${(v * 255).round()}';
    return 'Black prints at ${code(curve.green.first)}, white at ${code(curve.green.last)}';
  }
}

class _ToneCurvePainter extends CustomPainter {
  _ToneCurvePainter({
    required this.curve,
    required this.palette,
    required this.colors,
    required this.labelStyle,
  });

  final ToneCurveData curve;
  final Palette palette;
  final Map<String, Color> colors;
  final TextStyle labelStyle;

  // The plane, in the 280-point-wide design space the inspector's charts share.
  static const _left = 12.0, _right = 268.0, _top = 6.0, _bottom = 150.0;

  double _x(double code) => _left + code / 255 * (_right - _left);
  double _y(double value) => _bottom - value.clamp(0.0, 1.0) * (_bottom - _top);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 280;
    canvas.save();
    canvas.scale(k);
    final hairline = 1 / k;

    // The photograph's tones, behind everything: a square-root scale keeps a sky's spike from
    // flattening the rest.
    final counts = smoothHistogram(curve.histogram);
    final peak = counts.fold<double>(0, (m, v) => math.max(m, v.toDouble()));
    if (peak > 0) {
      final fill = Path()..moveTo(_x(0), _bottom);
      for (var i = 0; i < counts.length; i++) {
        fill.lineTo(_x(i.toDouble()), _bottom - math.sqrt(counts[i] / peak) * (_bottom - _top));
      }
      fill
        ..lineTo(_x(255), _bottom)
        ..close();
      canvas.drawPath(fill, Paint()..color = colors['luma']!.withValues(alpha: .16));
    }

    // Quarter grid, the frame, and the identity the curves are read against.
    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = hairline;
    for (var q = 0; q <= 4; q++) {
      final code = q * 255 / 4;
      canvas.drawLine(Offset(_x(code), _top), Offset(_x(code), _bottom), grid);
      canvas.drawLine(Offset(_left, _y(q / 4)), Offset(_right, _y(q / 4)), grid);
    }
    final identity = Paint()
      ..color = palette.muted.withValues(alpha: .5)
      ..strokeWidth = hairline;
    for (var d = 0.0; d < 1; d += 0.04) {
      canvas.drawLine(Offset(_x(d * 255), _y(d)),
          Offset(_x(math.min(d + 0.02, 1) * 255), _y(math.min(d + 0.02, 1))), identity);
    }

    for (final (values, name) in [
      (curve.red, 'red'),
      (curve.green, 'green'),
      (curve.blue, 'blue'),
    ]) {
      final path = Path()..moveTo(_x(0), _y(values[0]));
      for (var i = 1; i < values.length; i++) {
        path.lineTo(_x(i * 255 / (values.length - 1)), _y(values[i]));
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = colors[name]!
            ..strokeWidth = 1.4
            ..strokeJoin = StrokeJoin.round);
    }

    for (final code in const [0, 128, 255]) {
      final label = TextPainter(
        text: TextSpan(text: '$code', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = (_x(code.toDouble()) - label.width / 2).clamp(0.0, 280 - label.width);
      label.paint(canvas, Offset(x, _bottom + 4));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ToneCurvePainter old) =>
      !identical(old.curve, curve) || old.palette != palette || old.colors != colors;
}
