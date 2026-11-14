// What the pointer picks on a scanned negative for its reading (model/negatives.dart): a click
// samples the clear film or a neutral where it lands; with Pick Clear Film Area, a rectangle
// drawn over some clear film gives the clearest film in it.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';

/// The rectangle a drag from `from` to `to` draws on a picture `size` across, as shares of it
/// and held inside it; null for one too small to be meant, under four pixels either way.
Rect? drawnArea(Offset from, Offset to, Size size) {
  if (size.width <= 0 || size.height <= 0) return null;
  final drawn = Rect.fromPoints(from, to).intersect(Offset.zero & size);
  if (drawn.width < 4 || drawn.height < 4) return null;
  return Rect.fromLTRB(drawn.left / size.width, drawn.top / size.height,
      drawn.right / size.width, drawn.bottom / size.height);
}

class FilmBaseSampler extends StatefulWidget {
  const FilmBaseSampler({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<FilmBaseSampler> createState() => _FilmBaseSamplerState();
}

class _FilmBaseSamplerState extends State<FilmBaseSampler> {
  /// The rectangle being drawn, from where the pointer went down to where it is.
  Offset? _from, _to;

  EditorModel get editor => widget.editor;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (!editor.negatives.pickingArea) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => editor.negatives.sample(Offset(
                  d.localPosition.dx / size.width, d.localPosition.dy / size.height)),
            );
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => setState(() => _from = _to = d.localPosition),
            onPanUpdate: (d) => setState(() => _to = d.localPosition),
            onPanCancel: () => setState(() => _from = _to = null),
            onPanEnd: (_) {
              final (from, to) = (_from, _to);
              setState(() => _from = _to = null);
              if (from == null || to == null) return;
              final area = drawnArea(from, to, size);
              if (area != null) editor.negatives.sampleArea(area);
            },
            child: CustomPaint(
              size: Size.infinite,
              painter: _AreaPainter(
                  _from == null || _to == null ? null : Rect.fromPoints(_from!, _to!)),
            ),
          );
        }),
      );
}

class _AreaPainter extends CustomPainter {
  _AreaPainter(this.area);
  final Rect? area;

  @override
  void paint(Canvas canvas, Size size) {
    final area = this.area?.intersect(Offset.zero & size);
    if (area == null || area.width <= 0 || area.height <= 0) return;
    canvas.drawRect(area, Paint()..color = const Color(0x33FFFFFF));
    canvas.drawRect(
      area.inflate(.5),
      Paint()
        ..color = const Color(0x88000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawRect(
      area,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_AreaPainter old) => old.area != area;
}
