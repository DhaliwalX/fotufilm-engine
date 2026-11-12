// The inspector's tone curve, above its heading: how the edit's film, output medium and grade
// carry each input tone, per channel, over the developed picture's tones, which follow the edit
// as the curve does.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/histogram.dart' show smoothHistogram;
import '../../model/tone_curve.dart';
import '../theme/theme.dart';
import '../workspace/histogram_panel.dart' show histogramColors;

class ToneCurveChart extends StatefulWidget {
  const ToneCurveChart({super.key, required this.editor, this.padding = EdgeInsets.zero});
  final EditorModel editor;

  /// Around the chart while it is drawn; it takes no room while it has no curve.
  final EdgeInsets padding;

  @override
  State<ToneCurveChart> createState() => _ToneCurveChartState();
}

class _ToneCurveChartState extends State<ToneCurveChart> {
  // The curve, and the editor for the picture's tones as the renderer measures them.
  late Listenable _changes;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(ToneCurveChart old) {
    super.didUpdateWidget(old);
    if (identical(old.editor, widget.editor)) return;
    old.editor.toneCurve.chart(false);
    _watch();
  }

  void _watch() {
    final editor = widget.editor;
    _changes = Listenable.merge([editor.toneCurve, editor]);
    // While the chart is shown the renderer measures the developed picture for it.
    editor.toneCurve.chart(true);
  }

  @override
  void dispose() {
    widget.editor.toneCurve.chart(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _changes,
        builder: (context, _) {
          final editor = widget.editor;
          final curve = (editor.toneCurve..follow()).curve;
          if (curve == null) return const SizedBox.shrink();
          final palette = Palette.of(context);
          return Padding(
            padding: widget.padding,
            child: Semantics(
              label: 'Tone curve',
              value: _description(curve),
              child: AspectRatio(
                aspectRatio: 280 / 168,
                child: CustomPaint(
                  painter: ToneCurvePainter(
                    curve: curve,
                    tones: editor.histogram?.luma,
                    palette: palette,
                    colors: histogramColors(palette.dark),
                    labelStyle: editorText(context, size: 8, color: palette.muted),
                  ),
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

class ToneCurvePainter extends CustomPainter {
  ToneCurvePainter({
    required this.curve,
    required this.tones,
    required this.palette,
    required this.colors,
    required this.labelStyle,
  });

  final ToneCurveData curve;

  /// The developed picture's pixels at each code, by luma; null until they are measured.
  final Uint32List? tones;
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

    // The picture's tones, behind everything: a square-root scale keeps a sky's spike from
    // flattening the rest.
    final counts = smoothHistogram(tones ?? const <int>[]);
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
  bool shouldRepaint(ToneCurvePainter old) =>
      !identical(old.curve, curve) ||
      !identical(old.tones, tones) ||
      old.palette != palette ||
      old.colors != colors;
}
