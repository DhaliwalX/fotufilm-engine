// The floating histogram (web/src/HistogramPanel.jsx, HistogramPlot.jsx, histogram.css): at the
// viewer's top left, moved by its header and resized from its corner. RGB, Luma, Chroma, OKLab L
// or OKLab a/b, on a log or linear count axis. Made small, it is the graph alone, moved by
// dragging the graph.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/histogram.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

class HistogramPanel extends StatefulWidget {
  const HistogramPanel({super.key, required this.data, required this.onClose, this.labels});
  final HistogramData? data;
  final VoidCallback onClose;

  /// The catalogue's HISTOGRAM wording: the title, the views and modes.
  final Json? labels;

  /// The view shown, kept while the panel closes and opens again, as the web panel's is.
  static final view = ValueNotifier('rgb');

  @override
  State<HistogramPanel> createState() => _HistogramPanelState();
}

class _HistogramPanelState extends State<HistogramPanel> {
  static const _headerHeight = 38.0;
  static const _minSize = Size(220, 150);

  Rect _rect = Metrics.histogramRect;
  bool _log = true;
  bool _small = false;

  static const _views = [
    {'id': 'rgb', 'label': 'RGB'},
    {'id': 'luma', 'label': 'Luma'},
    {'id': 'chroma', 'label': 'Chroma'},
    {'id': 'oklab-l', 'label': 'OKLab L'},
    {'id': 'oklab-ab', 'label': 'OKLab a/b'},
  ];

  String get _view => HistogramPanel.view.value;

  @override
  void initState() {
    super.initState();
    HistogramPanel.view.addListener(_viewChanged);
  }

  @override
  void dispose() {
    HistogramPanel.view.removeListener(_viewChanged);
    super.dispose();
  }

  void _viewChanged() => setState(() {});

  void _move(Offset delta) => setState(() => _rect = _rect.shift(delta));

  /// The arrow keys move or resize it 8 points, 32 with Shift (use-floating-panel.js).
  static Offset _keyed(Offset direction, bool shift) => direction * (shift ? 32 : 8);

  void _resize(Offset delta) => setState(() => _rect = Rect.fromLTWH(
        _rect.left,
        _rect.top,
        math.max(_minSize.width, _rect.width + delta.dx),
        math.max(_minSize.height, _rect.height + delta.dy),
      ));

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final labels = widget.labels ?? const {};
    // A small dead band keeps the controls from flickering at the boundary.
    _small = _small
        ? _rect.width < 340 || _rect.height < 200
        : _rect.width < 320 || _rect.height < 180;
    final views = ((labels['views'] as List?) ?? _views).cast<Map>();
    final view = HistogramView.all[_view]!;
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
            if (!_small)
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
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: KeyTarget(
                            label: labels['move'] as String? ?? 'Move histogram',
                            onNudge: (direction, shift) => _move(_keyed(direction, shift)),
                            child: Text(labels['title'] as String? ?? 'Histogram',
                                overflow: TextOverflow.ellipsis,
                                style: editorText(context, weight: FontWeight.w700)),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 104,
                        child: PickerField<String>(
                          value: _view,
                          options: [
                            for (final v in views)
                              PickerOption(v['id'] as String, v['label'] as String),
                          ],
                          onChanged: (v) => HistogramPanel.view.value = v,
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
                      QuietButton(
                          icon: 'close',
                          tooltip: labels['close'] as String? ?? 'Close histogram',
                          onPressed: widget.onClose,
                          iconSize: 16),
                    ]),
                  ),
                ),
              ),
            Expanded(
              child: MouseRegion(
                cursor: _small ? SystemMouseCursors.move : MouseCursor.defer,
                child: GestureDetector(
                  onPanUpdate: _small ? (d) => _move(d.delta) : null,
                  child: Padding(
                    padding: _small ? const EdgeInsets.all(6) : const EdgeInsets.fromLTRB(10, 4, 16, 18),
                    child: _plot(context, view),
                  ),
                ),
              ),
            ),
          ]),
          Positioned(
            right: 2,
            bottom: 2,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: KeyTarget(
                label: labels['resize'] as String? ?? 'Resize histogram',
                onNudge: (direction, shift) => _resize(_keyed(direction, shift)),
                child: GestureDetector(
                onPanUpdate: (d) => _resize(d.delta),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  // A graph-only panel keeps an invisible corner, so it can always be enlarged.
                  child: _small ? null : CustomPaint(painter: _ResizeGrip(palette.muted)),
                ),
              ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _plot(BuildContext context, HistogramView view) {
    final palette = Palette.of(context);
    final muted = editorText(context, size: TextSizes.caption, color: palette.muted);
    final graph = Opacity(
      // The last graph stays while a measure is pending.
      opacity: widget.data == null ? .55 : 1,
      child: CustomPaint(
        size: Size.infinite,
        painter: _HistogramPainter(
          widget.data,
          view,
          _log,
          palette,
          colors: histogramColors(palette.dark),
          decorated: !_small,
          labelStyle: muted,
        ),
      ),
    );
    if (_small) return Semantics(label: view.description, child: graph);
    final colors = histogramColors(palette.dark);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 14,
        child: Row(children: [
          Expanded(child: Text('Pixel count', style: muted)),
          for (final (i, (label, color)) in view.legend.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Text(label, style: muted.copyWith(color: colors[color])),
          ],
        ]),
      ),
      Expanded(
        child: Semantics(
          label: '${view.description}, ${_log ? 'logarithmic' : 'linear'} pixel counts',
          child: graph,
        ),
      ),
      Container(
        margin: const EdgeInsets.only(left: 34, right: 3),
        height: 5,
        decoration: view.centered
            ? null
            : const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF000000), Color(0xFFFFFFFF)]),
              ),
        child: view.centered
            ? Center(child: Container(width: 1, color: palette.muted))
            : null,
      ),
      Padding(
        padding: const EdgeInsets.only(left: 34),
        child: SizedBox(
          height: 14,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (final t in view.ticks) Text(t, style: muted)],
          ),
        ),
      ),
    ]);
  }
}

/// The histogram's colours by name (histogram.css `--histogram-*`).
Map<String, Color> histogramColors(bool dark) => dark
    ? const {
        'red': Color(0xFFF08791),
        'green': Color(0xFF76C994),
        'blue': Color(0xFF89B1F4),
        'luma': Color(0xFFD6DBE5),
        'a': Color(0xFFEC90BF),
        'b': Color(0xFFE6C060),
      }
    : const {
        'red': Color(0xFFCD525C),
        'green': Color(0xFF2E8853),
        'blue': Color(0xFF467BDD),
        'luma': Color(0xFF666D78),
        'a': Color(0xFFAE457E),
        'b': Color(0xFF987019),
      };

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.data, this.view, this.log, this.palette,
      {required this.colors, required this.decorated, required this.labelStyle});
  final HistogramData? data;
  final HistogramView view;
  final bool log;
  final Palette palette;
  final Map<String, Color> colors;

  /// The count axis and its labels; a small panel draws the curves alone.
  final bool decorated;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final data = this.data;
    if (data == null || data.count == 0) return;
    final values = {for (final c in view.channels) c: smoothHistogram(data.channels[c])};
    final peak = values.values.expand((v) => v).fold(1.0, math.max);
    final axis = histogramCountAxis(peak, log: log);
    final left = decorated ? 34.0 : 3.0;
    final right = math.max(left + 1, size.width - 3);
    final top = decorated ? 8.0 : 3.0;
    final bottom = size.height - (decorated ? 6 : 3);
    double x(double i) => left + i / 255 * (right - left);
    double y(double v) => bottom - v * (bottom - top);
    double height(double count) => histogramCountHeight(count, axis.max, log: log);

    if (decorated) {
      final grid = Paint()
        ..color = palette.border
        ..strokeWidth = .6;
      var lastY = double.infinity;
      for (final count in axis.ticks) {
        final at = y(height(count));
        if (lastY - at < 15 && count != axis.max) continue;
        lastY = at;
        final label = TextPainter(
          text: TextSpan(text: histogramTickLabel(count), style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, Offset(left - 5 - label.width, at - label.height / 2));
        canvas.drawLine(Offset(left, at), Offset(right, at), grid);
      }
      if (view.centered) {
        final dash = Paint()
          ..color = palette.muted.withValues(alpha: .45)
          ..strokeWidth = 1;
        for (var d = top; d < bottom; d += 7) {
          canvas.drawLine(
              Offset(x(127.5), d), Offset(x(127.5), math.min(bottom, d + 3)), dash);
        }
      }
    }

    for (final c in view.channels) {
      final color = colors[histogramPalette[c]]!;
      final heights = [for (final v in values[c]!) height(v)];
      final curve = _trace(heights, x, y);
      final fill = Path.from(curve)
        ..lineTo(right, bottom)
        ..lineTo(left, bottom)
        ..close();
      canvas.drawPath(fill, Paint()..color = color.withValues(alpha: .12));
      canvas.drawPath(
          curve,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4);
    }
  }

  /// Quadratic midpoints stay inside adjacent values, so smoothing cannot overshoot
  /// (histogram-curves.js `traceHistogram`).
  static Path _trace(List<double> values, double Function(double) x, double Function(double) y) {
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      final p = i - 1;
      path.quadraticBezierTo(x(p.toDouble()), y(values[p]), (x(p.toDouble()) + x(i.toDouble())) / 2,
          (y(values[p]) + y(values[i])) / 2);
    }
    final last = values.length - 1;
    path.lineTo(x(last.toDouble()), y(values[last]));
    return path;
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.data != data ||
      old.view != view ||
      old.log != log ||
      old.palette != palette ||
      old.decorated != decorated;
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
      canvas.drawLine(Offset(size.width - 4, size.height - 4 - d),
          Offset(size.width - 4 - d, size.height - 4), paint);
    }
  }

  @override
  bool shouldRepaint(_ResizeGrip old) => old.color != color;
}
