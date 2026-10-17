// The floating histogram (web/src/HistogramPanel.jsx, histogram.css): at the viewer's top left,
// moved by its header and resized from its corner, RGB or luma on a log or linear scale.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/histogram.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

class HistogramPanel extends StatefulWidget {
  const HistogramPanel({super.key, required this.data, required this.onClose});
  final HistogramData? data;
  final VoidCallback onClose;

  @override
  State<HistogramPanel> createState() => _HistogramPanelState();
}

class _HistogramPanelState extends State<HistogramPanel> {
  static const _headerHeight = 38.0;
  static const _minSize = Size(220, 150);

  Rect _rect = Metrics.histogramRect;
  String _view = 'rgb';
  bool _log = true;

  void _move(Offset delta) => setState(() => _rect = _rect.shift(delta));

  void _resize(Offset delta) => setState(() => _rect = Rect.fromLTWH(
        _rect.left,
        _rect.top,
        math.max(_minSize.width, _rect.width + delta.dx),
        math.max(_minSize.height, _rect.height + delta.dy),
      ));

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final small = _rect.width < 320 || _rect.height < 180;
    final muted = editorText(context, size: TextSizes.caption, color: palette.muted);
    return Positioned.fromRect(
      rect: _rect,
      child: Container(
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 30, offset: Offset(0, 8))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                onPanUpdate: (d) => _move(d.delta),
                child: Container(
                  height: _headerHeight,
                  color: const Color(0x00000000),
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 4),
                  child: Row(children: [
                    Expanded(
                      child: Text('Histogram',
                          style: editorText(context, weight: FontWeight.w700)),
                    ),
                    if (!small) ...[
                      SizedBox(
                        width: 84,
                        child: PickerField<String>(
                          value: _view,
                          options: const [PickerOption('rgb', 'RGB'), PickerOption('luma', 'Luma')],
                          onChanged: (v) => setState(() => _view = v),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 80,
                        child: PickerField<bool>(
                          value: _log,
                          options: const [PickerOption(true, 'Log'), PickerOption(false, 'Linear')],
                          onChanged: (v) => setState(() => _log = v),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    QuietButton(
                        icon: 'close', tooltip: 'Close histogram', onPressed: widget.onClose,
                        iconSize: 16),
                  ]),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 16, 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SizedBox(
                        width: 28,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [Text(_log ? 'log' : 'max', style: muted), Text('0', style: muted)],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: CustomPaint(
                            painter: _HistogramPainter(widget.data, _view, _log, palette)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    margin: const EdgeInsets.only(left: 34, right: 3),
                    height: 5,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: [Color(0xFF000000), Color(0xFFFFFFFF)]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 34, top: 1),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final t in const ['0', '64', '128', '192', '255']) Text(t, style: muted),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ]),
          Positioned(
            right: 2,
            bottom: 2,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: GestureDetector(
                onPanUpdate: (d) => _resize(d.delta),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CustomPaint(painter: _ResizeGrip(palette.muted)),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.data, this.view, this.log, this.palette);
  final HistogramData? data;
  final String view;
  final bool log;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final data = this.data;
    if (data == null || data.count == 0) return;
    double f(int v) => log ? math.log(1 + v) : v.toDouble();
    final dark = palette.dark;
    final channels = view == 'rgb'
        ? [
            (data.red, dark ? const Color(0xFFF08791) : const Color(0xFFCD525C)),
            (data.green, dark ? const Color(0xFF76C994) : const Color(0xFF2E8853)),
            (data.blue, dark ? const Color(0xFF89B1F4) : const Color(0xFF467BDD)),
          ]
        : [(data.luma, dark ? const Color(0xFFD6DBE5) : const Color(0xFF666D78))];
    // The ends are clipped pixels; the scale follows the tones between them.
    var peak = 1.0;
    for (final (bins, _) in channels) {
      for (var i = 1; i < 255; i++) {
        peak = math.max(peak, f(bins[i]));
      }
    }
    for (final (bins, color) in channels) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < 256; i++) {
        path.lineTo(size.width * i / 255, size.height * (1 - math.min(1.0, f(bins[i]) / peak)));
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: view == 'rgb' ? .38 : .5));
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.data != data || old.view != view || old.log != log || old.palette != palette;
}

/// The corner's diagonal hatching.
class _ResizeGrip extends CustomPainter {
  _ResizeGrip(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var d = 4.0; d <= 12; d += 4) {
      canvas.drawLine(Offset(size.width - 2, size.height - 2 - d),
          Offset(size.width - 2 - d, size.height - 2), paint);
    }
  }

  @override
  bool shouldRepaint(_ResizeGrip old) => old.color != color;
}
