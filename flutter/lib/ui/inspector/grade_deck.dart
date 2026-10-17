// The grade deck (web/src/editor/GradeDeck.jsx, grade-deck.js, styles/inspector.css), compact: a
// band switch, the band's colour pad (warm across, green up) over a wash, and its level capsule.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

class GradeDeck extends StatefulWidget {
  const GradeDeck({super.key, required this.editor});
  final EditorModel editor;

  static const bands = ['Shadows', 'Midtones', 'Highlights'];
  static const axes = ['Warmth', 'Tint', 'Level'];

  @override
  State<GradeDeck> createState() => _GradeDeckState();
}

class _GradeDeckState extends State<GradeDeck> {
  String _band = 'Shadows';

  // Each band's pad: its ground and how strongly the wash shows.
  static const _ground = {
    'Shadows': (Color(0xFF1A1A1A), .62),
    'Midtones': (Color(0xFF2B2B2B), .55),
    'Highlights': (Color(0xFF424242), .46),
  };
  static const _capsule = {
    'Shadows': [Color(0xFF000000), Color(0xFF616161)],
    'Midtones': [Color(0xFF1F1F1F), Color(0xFF737373), Color(0xFFC7C7C7)],
    'Highlights': [Color(0xFF595959), Color(0xFFFFFFFF)],
  };

  /// How far in from the pad's edges its range ends.
  static const _padInset = 16.0;
  static const _capsuleHeight = 22.0;

  Map get _params => widget.editor.edit['params'] as Map;
  double _get(String axis) => (_params['grade$_band$axis'] as num? ?? 0).toDouble();

  void _set(Map<String, double> changes) => widget.editor.setParams(
      {for (final MapEntry(:key, :value) in changes.entries) 'grade$_band$key': value},
      'grade-$_band');

  void _pad(Offset p, Size size) {
    final spanX = size.width / 2 - _padInset, spanY = size.height / 2 - _padInset;
    var warmth = ((p.dx - size.width / 2) / spanX).clamp(-1.0, 1.0);
    var tint = ((size.height / 2 - p.dy) / spanY).clamp(-1.0, 1.0);
    // The centre holds, so neutral is easy to find.
    if (warmth.abs() < .06 && tint.abs() < .06) warmth = tint = 0;
    _set({'Warmth': warmth, 'Tint': tint});
  }

  void _level(Offset p, Size size) {
    final usable = math.max(size.width - size.height, 1.0);
    var level = ((p.dx - size.height / 2) / usable).clamp(0.0, 1.0) * 2 - 1;
    if (level.abs() < .04) level = 0;
    _set({'Level': level});
  }

  /// Arrow keys move the pad and the level by this much, Shift by a tenth of it (GradeDeck.jsx),
  /// each one step of the history.
  static const _step = .05;

  void _nudge(Map<String, double> changes) {
    _set({
      for (final MapEntry(:key, :value) in changes.entries)
        key: (_get(key) + value).clamp(-1.0, 1.0).toDouble(),
    });
    widget.editor.endEdit();
  }

  static String _cast(double x, double y) {
    final h = x > 0 ? 'Warm' : 'Cool', v = y > 0 ? 'Green' : 'Magenta';
    if (x != 0 && y != 0) {
      return x.abs() >= y.abs() ? '$h ${v.toLowerCase()}' : '$v ${h.toLowerCase()}';
    }
    return x != 0 ? h : v;
  }

  String get _reading {
    final warmth = _get('Warmth'), tint = _get('Tint'), level = _get('Level');
    final rounded = (level * 100).round();
    return [
      if (warmth != 0 || tint != 0) _cast(warmth, tint),
      if (level != 0) '${rounded < 0 ? '-' : '+'}${rounded.abs()}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final caps = editorText(context, size: TextSizes.label, weight: FontWeight.w700)
        .copyWith(letterSpacing: .66);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedControl<String>(
        items: [for (final b in GradeDeck.bands) (b, b)],
        selected: _band,
        onChanged: (b) => setState(() => _band = b),
      ),
      const SizedBox(height: Metrics.gradeGap),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(_band.toUpperCase(), style: caps),
        Text(_reading.toUpperCase(),
            style: caps.copyWith(fontWeight: FontWeight.w500, color: palette.muted)),
      ]),
      const SizedBox(height: Metrics.gradeGap),
      LayoutBuilder(builder: (context, constraints) => _padArea(constraints.maxWidth)),
      const SizedBox(height: Metrics.gradeGap),
      LayoutBuilder(builder: (context, constraints) => _levelCapsule(constraints.maxWidth)),
    ]);
  }

  Widget _padArea(double width) {
    final size = Size(width, Metrics.gradePadHeight);
    final (ground, wash) = _ground[_band]!;
    final knob = Offset(size.width / 2 + _get('Warmth') * (size.width / 2 - _padInset),
        size.height / 2 - _get('Tint') * (size.height / 2 - _padInset));
    final warmth = _get('Warmth'), tint = _get('Tint');
    return KeyTarget(
      label: 'Color balance pad',
      value: warmth == 0 && tint == 0 ? 'Neutral' : _cast(warmth, tint),
      onNudge: (direction, shift) {
        final step = shift ? _step / 10 : _step;
        _nudge({'Warmth': direction.dx * step, 'Tint': -direction.dy * step});
      },
      radius: Metrics.gradePadRadius,
      child: GestureDetector(
      onPanDown: (d) => _pad(d.localPosition, size),
      onPanUpdate: (d) => _pad(d.localPosition, size),
      onPanEnd: (_) => widget.editor.endEdit(),
      onPanCancel: widget.editor.endEdit,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Metrics.gradePadRadius),
        child: CustomPaint(
          size: size,
          painter: _PadPainter(ground: ground, wash: wash, knob: knob),
        ),
      ),
      ),
    );
  }

  Widget _levelCapsule(double width) {
    final size = Size(width, _capsuleHeight);
    final usable = math.max(size.width - size.height, 1.0);
    final x = size.height / 2 + (_get('Level') + 1) / 2 * usable;
    String reading(double value) {
      final level = (value.clamp(-1.0, 1.0) * 100).round();
      return level == 0 ? '0' : '${level < 0 ? '-' : '+'}${level.abs()}';
    }
    return KeyTarget(
      label: 'Level',
      value: reading(_get('Level')),
      increasedValue: reading(_get('Level') + _step),
      decreasedValue: reading(_get('Level') - _step),
      onIncrease: (_) => _nudge({'Level': _step}),
      onDecrease: (_) => _nudge({'Level': -_step}),
      // Right and up raise it.
      onNudge: (direction, shift) =>
          _nudge({'Level': (direction.dx - direction.dy) * (shift ? _step / 10 : _step)}),
      radius: size.height / 2,
      child: GestureDetector(
      onPanDown: (d) => _level(d.localPosition, size),
      onPanUpdate: (d) => _level(d.localPosition, size),
      onPanEnd: (_) => widget.editor.endEdit(),
      onPanCancel: widget.editor.endEdit,
      child: Container(
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size.height / 2),
          gradient: LinearGradient(colors: _capsule[_band]!),
          boxShadow: const [BoxShadow(color: Color(0x1FFFFFFF), spreadRadius: .5)],
        ),
        child: Stack(children: [
          Positioned(
            left: size.width / 2 - .5,
            top: size.height / 4,
            width: 1,
            height: size.height / 2,
            child: const ColoredBox(color: Color(0x59FFFFFF)),
          ),
          Positioned(
            left: x - (size.height - 4) / 2,
            top: 2,
            child: Container(
              width: size.height - 4,
              height: size.height - 4,
              decoration: const BoxDecoration(
                color: Color(0xFFFFFFFF),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x73000000), blurRadius: 2, offset: Offset(0, 1))],
              ),
            ),
          ),
        ]),
      ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter({required this.ground, required this.wash, required this.knob});
  final Color ground;
  final double wash;
  final Offset knob;

  static const _inset = 16.0;
  static const _knob = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = ground);
    const clear = Color(0x00000000);
    // Cool to warm across.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Color.fromRGBO(89, 128, 191, wash), clear, clear, Color.fromRGBO(230, 140, 51, wash)],
          stops: const [0, .5, .5, 1],
        ).createShader(rect),
    );
    // Green above, magenta below.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromRGBO(102, 191, 89, wash * .9),
            clear,
            clear,
            Color.fromRGBO(191, 77, 140, wash * .9),
          ],
          stops: const [0, .5, .5, 1],
        ).createShader(rect),
    );
    // An 11×9 grid of dots, the centre row and column brighter.
    for (var i = 0; i < 11; i++) {
      for (var j = 0; j < 9; j++) {
        final x = _inset + (size.width - _inset * 2) * i / 10;
        final y = _inset + (size.height - _inset * 2) * j / 8;
        final centre = i == 5 || j == 4;
        canvas.drawCircle(Offset(x, y), 1.4,
            Paint()..color = Color.fromRGBO(255, 255, 255, centre ? .65 : .38));
      }
    }
    canvas.drawCircle(
      size.center(Offset.zero),
      4.5,
      Paint()
        ..color = const Color(0xCCFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawCircle(
        knob.translate(0, 1),
        _knob / 2,
        Paint()
          ..color = const Color(0x80000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    canvas.drawCircle(knob, _knob / 2, Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(_PadPainter old) =>
      old.ground != ground || old.wash != wash || old.knob != knob;
}
