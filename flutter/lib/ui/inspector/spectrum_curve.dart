// A curve over wavelength (web/src/SpectrumCurve.jsx, styles/inspector.css `.spectrum-control`):
// a handle at each of the control's wavelengths, dragged up or down in tenths of a stop, drawn on
// the web editor's 280 × 108 plane. Halation's Return Spectrum is one.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

class SpectrumCurve extends StatefulWidget {
  const SpectrumCurve({
    super.key,
    required this.title,
    required this.curve,
    required this.values,
    required this.onChanged,
    required this.onReset,
    required this.onEnd,
    this.detail,
    this.enabled = true,
  });

  final String title;
  final String? detail;

  /// The control's `curve`: `handles` in nm over `domainMin`…`domainMax`, values `min`…`max`.
  final Json curve;
  final List<double> values;
  final ValueChanged<List<double>> onChanged;
  final VoidCallback onReset, onEnd;
  final bool enabled;

  @override
  State<SpectrumCurve> createState() => _SpectrumCurveState();
}

class _SpectrumCurveState extends State<SpectrumCurve> {
  static const _plane = Size(280, 108);
  int? _dragged;

  List<double> get _handles => [for (final nm in widget.curve['handles'] as List) (nm as num).toDouble()];
  double get _min => (widget.curve['min'] as num).toDouble();
  double get _max => (widget.curve['max'] as num).toDouble();

  void _start(Offset at, double width) {
    final x = at.dx / width * _plane.width;
    final handles = _handles;
    var best = 0;
    for (var i = 1; i < handles.length; i++) {
      if ((_x(handles[i]) - x).abs() < (_x(handles[best]) - x).abs()) best = i;
    }
    _dragged = best;
    _move(at, width);
  }

  void _move(Offset at, double width) {
    final index = _dragged;
    if (index == null) return;
    final y = at.dy / (width * _plane.height / _plane.width) * _plane.height;
    final value = _max - (y - 8) / 76 * (_max - _min);
    final next = [...widget.values];
    next[index] = ((value * 10).round() / 10).clamp(_min, _max).toDouble();
    widget.onChanged(next);
  }

  void _end() {
    _dragged = null;
    widget.onEnd();
  }

  double _x(double nm) {
    final lo = (widget.curve['domainMin'] as num).toDouble();
    final hi = (widget.curve['domainMax'] as num).toDouble();
    return 12 + (nm - lo) / (hi - lo) * 256;
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = widget.enabled;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: FieldLabel(widget.title, detail: widget.detail)),
          QuietButton(
            label: 'Reset ${widget.title}',
            onPressed: enabled
                ? () {
                    widget.onReset();
                    widget.onEnd();
                  }
                : null,
          ),
        ]),
        const SizedBox(height: Metrics.labelGap),
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: enabled ? (d) => _start(d.localPosition, width) : null,
            onPanUpdate: enabled ? (d) => _move(d.localPosition, width) : null,
            onPanEnd: enabled ? (_) => _end() : null,
            onPanCancel: enabled ? _end : null,
            child: MouseRegion(
              cursor: enabled ? SystemMouseCursors.resizeUpDown : MouseCursor.defer,
              child: AspectRatio(
                aspectRatio: _plane.width / _plane.height,
                child: CustomPaint(
                  painter: _CurvePainter(
                    handles: _handles,
                    values: widget.values,
                    min: _min,
                    max: _max,
                    x: _x,
                    palette: palette,
                    labelStyle: editorText(context, size: 8, color: palette.muted),
                  ),
                ),
              ),
            ),
          );
        }),
      ]),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.handles,
    required this.values,
    required this.min,
    required this.max,
    required this.x,
    required this.palette,
    required this.labelStyle,
  });

  final List<double> handles, values;
  final double min, max;
  final double Function(double nm) x;
  final Palette palette;
  final TextStyle labelStyle;

  double _y(double value) => 8 + (max - value) / (max - min) * 76;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn in the web editor's plane, scaled to the width.
    final k = size.width / 280;
    canvas.save();
    canvas.scale(k);
    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = 1 / k;
    for (final v in [min, max]) {
      for (var gx = 12.0; gx < 268; gx += 5) {
        canvas.drawLine(Offset(gx, _y(v)), Offset(math.min(gx + 2, 268), _y(v)), grid);
      }
    }
    canvas.drawLine(Offset(12, _y(0)), Offset(268, _y(0)),
        Paint()
          ..color = palette.muted.withValues(alpha: .5)
          ..strokeWidth = 1 / k);
    final points = [for (var i = 0; i < handles.length; i++) Offset(x(handles[i]), _y(values[i]))];
    canvas.drawPath(
        Path()..addPolygon(points, false),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = palette.accent
          ..strokeWidth = 1.5);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], 4, Paint()..color = palette.accent);
      canvas.drawCircle(
          points[i],
          4,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = palette.panel
            ..strokeWidth = 1.5);
      final label = TextPainter(
        text: TextSpan(text: '${handles[i].round()}', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(points[i].dx - label.width / 2, 103 - label.height * .8));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.values.toString() != values.toString() || old.palette != palette;
}
