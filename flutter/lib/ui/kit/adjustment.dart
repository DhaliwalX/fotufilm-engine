// One adjustment, as web/src/Adjustment.jsx lays it out on the compact desktop: the control's
// name and help, then the slider between its low and high glyphs with the value at its end.
// Double-click the slider to reset it.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'fields.dart';
import 'focus.dart';
import 'icons.dart';

/// A slider's value as the number field shows it: up to three decimals, grouped thousands.
String formatNumber(double value, {int decimals = 3}) {
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  if (text == '-0') text = '0';
  final negative = text.startsWith('-');
  final parts = (negative ? text.substring(1) : text).split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${negative ? '-' : ''}$whole${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// What an adjustment ranges over and where it rests.
class SliderRange {
  const SliderRange({required this.min, required this.max, required this.step, required this.def});
  final double min, max, step, def;

  double snap(double v) =>
      (step > 0 ? (v / step).round() * step : v).clamp(min, max).toDouble();
}

class AdjustmentRow extends StatelessWidget {
  const AdjustmentRow({
    super.key,
    required this.label,
    required this.value,
    required this.range,
    required this.onChanged,
    this.onEnd,
    this.detail,
    this.ends,
    this.reciprocal = false,
    this.enabled = true,
  });

  final String label;
  final double value;
  final SliderRange range;
  final ValueChanged<double> onChanged;
  final VoidCallback? onEnd;
  final String? detail;

  /// The glyphs drawn at the slider's low and high ends.
  final (String, String)? ends;

  /// Temperature runs on a reciprocal (mired) scale along the track.
  final bool reciprocal;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final trackMin = reciprocal ? 1e6 / range.max : range.min;
    final trackMax = reciprocal ? 1e6 / range.min : range.max;
    final trackValue = reciprocal ? 1e6 / value : value;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FieldLabel(label, detail: detail),
          const SizedBox(height: Metrics.labelGap),
          Row(children: [
            if (ends != null) _End(ends!.$1),
            Expanded(
              child: TrackSlider(
                label: label,
                describe: (t) => formatNumber(reciprocal ? (1e6 / t).roundToDouble() : range.snap(t)),
                value: trackValue.clamp(trackMin, trackMax).toDouble(),
                min: trackMin,
                max: trackMax,
                // A key moves it a hundredth of the track, and never less than a step.
                keyStep: reciprocal ? null : math.max(range.step, (range.max - range.min) / 100),
                onChanged: (t) => onChanged(reciprocal ? (1e6 / t).roundToDouble() : range.snap(t)),
                onEnd: onEnd,
                onReset: () {
                  onChanged(range.def);
                  onEnd?.call();
                },
              ),
            ),
            if (ends != null) _End(ends!.$2),
            const SizedBox(width: 4),
            NumberBox(
              value: value,
              onSubmitted: (v) {
                onChanged(v.clamp(range.min, range.max).toDouble());
                onEnd?.call();
              },
            ),
          ]),
        ]),
      ),
    );
  }
}

class _End extends StatelessWidget {
  const _End(this.glyph);
  final String glyph;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Metrics.trackGap / 2),
        child: Glyph(glyph, size: Metrics.endGlyph),
      );
}

/// Spectrum's Slider at size S: a 4 px track filled from the minimum to the knob.
class TrackSlider extends StatefulWidget {
  const TrackSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onEnd,
    this.onReset,
    this.label,
    this.describe,
    this.keyStep,
  });

  final double value, min, max;
  final ValueChanged<double> onChanged;
  final VoidCallback? onEnd, onReset;

  /// What VoiceOver reads: its name, and a value along the track as the number field shows it.
  final String? label;
  final String Function(double value)? describe;

  /// How far an arrow key moves it; a hundredth of the track by default.
  final double? keyStep;

  @override
  State<TrackSlider> createState() => _TrackSliderState();
}

class _TrackSliderState extends State<TrackSlider> {
  static const _knob = Metrics.knob;

  /// The knob follows the pointer itself while the editor catches up with the value.
  double? _dragged;

  void _update(double dx, double width) {
    final t = ((dx - _knob / 2) / math.max(1, width - _knob)).clamp(0.0, 1.0);
    final value = widget.min + t * (widget.max - widget.min);
    setState(() => _dragged = value);
    widget.onChanged(value);
  }

  void _settle() {
    setState(() => _dragged = null);
    widget.onEnd?.call();
  }

  /// Where `steps` arrow keys take it.
  double _stepped(int steps) {
    final step = widget.keyStep ?? (widget.max - widget.min) / 100;
    return (widget.value + steps * step).clamp(widget.min, widget.max).toDouble();
  }

  /// An arrow key: one change, as a click on the track is.
  void _nudge(int steps) {
    widget.onChanged(_stepped(steps));
    widget.onEnd?.call();
  }

  String _describe(double value) => widget.describe?.call(value) ?? formatNumber(value);

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final span = widget.max - widget.min;
      final value = _dragged ?? widget.value;
      final t = span == 0 ? 0.0 : ((value - widget.min) / span).clamp(0.0, 1.0);
      final x = _knob / 2 + t * (width - _knob);
      return KeyTarget(
        label: widget.label,
        value: _describe(widget.value),
        increasedValue: _describe(_stepped(1)),
        decreasedValue: _describe(_stepped(-1)),
        onIncrease: _nudge,
        onDecrease: (steps) => _nudge(-steps),
        radius: Metrics.control / 2,
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onReset,
        onHorizontalDragStart: (d) => _update(d.localPosition.dx, width),
        onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, width),
        onHorizontalDragEnd: (_) => _settle(),
        onTapUp: (d) {
          _update(d.localPosition.dx, width);
          _settle();
        },
        child: SizedBox(
          height: Metrics.control,
          child: CustomPaint(painter: _TrackPainter(x, palette)),
        ),
      ),
      );
    });
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter(this.x, this.palette);
  final double x;
  final Palette palette;
  static const _knob = Metrics.knob;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = RRect.fromLTRBR(_knob / 2, y - 2, size.width - _knob / 2, y + 2,
        const Radius.circular(2));
    canvas.drawRRect(track, Paint()..color = palette.gray300);
    canvas.drawRRect(
        RRect.fromLTRBR(_knob / 2, y - 2, x, y + 2, const Radius.circular(2)),
        Paint()..color = palette.gray700);
    final centre = Offset(x, y);
    canvas.drawCircle(centre.translate(0, 1), _knob / 2 + .5,
        Paint()..color = const Color(0x40000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    canvas.drawCircle(centre, _knob / 2,
        Paint()..color = palette.dark ? const Color(0xFFF2F2F2) : const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.x != x || old.palette != palette;
}

/// Spectrum's NumberField at size S without its stepper, in the soft field fill.
class NumberBox extends StatefulWidget {
  const NumberBox({super.key, required this.value, required this.onSubmitted});
  final double value;
  final ValueChanged<double> onSubmitted;

  @override
  State<NumberBox> createState() => _NumberBoxState();
}

class _NumberBoxState extends State<NumberBox> {
  late final _controller = TextEditingController(text: formatNumber(widget.value));
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(NumberBox old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) _controller.text = formatNumber(widget.value);
  }

  void _commit() {
    final parsed = double.tryParse(_controller.text.replaceAll(',', '').trim());
    if (parsed != null && parsed.isFinite) {
      widget.onSubmitted(parsed);
    } else {
      _controller.text = formatNumber(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        width: Metrics.numberWidth,
        height: Metrics.control,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
            color: Palette.of(context).fieldFill,
            borderRadius: BorderRadius.circular(Metrics.radius)),
        child: EditableField(
          controller: _controller,
          focusNode: _focus,
          style: editorText(context),
          onSubmitted: (_) => _commit(),
        ),
      );
}
