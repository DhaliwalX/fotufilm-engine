// The crop over the whole frame while the Crop tool is open (web/src/CropOverlay.jsx and .css):
// the frame outside the crop darkened, the crop's outline, its corner and edge handles, and the
// rule of thirds while it moves. Dragging a handle resizes the crop, held to its ratio when one is
// chosen; dragging inside moves it. A drag is one step of the history, made when it is let go.
// Return applies the tool and Escape leaves it (app/editor_shortcuts.dart).
import 'dart:convert';

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/widgets.dart';

import '../../model/crop_geometry.dart';
import '../../model/editor.dart';
import '../theme/theme.dart';

/// The crop overlay over `photo`, the frame's rectangle in the viewer, when the frame on show is
/// the tool's uncropped one.
List<Widget> cropOverlays(EditorModel editor, Rect photo) {
  final doc = editor.active;
  if (doc == null || !editor.crop.showing || !doc.shownUncropped) return const [];
  return [
    Positioned.fromRect(
      rect: photo.inflate(CropOverlay.margin),
      child: CropOverlay(key: CropOverlay.surface, editor: editor, photo: photo.size),
    ),
  ];
}

class CropOverlay extends StatefulWidget {
  const CropOverlay({super.key, required this.editor, required this.photo});
  final EditorModel editor;

  /// The frame's size in the viewer.
  final Size photo;

  /// Room around the frame for the handles on its edges.
  static const margin = 16.0;

  /// The overlay on show, for the driver to find its handles.
  static final surface = GlobalKey<CropOverlayState>();

  @override
  State<CropOverlay> createState() => CropOverlayState();
}

class CropOverlayState extends State<CropOverlay> {
  // CropOverlay.css and viewer.css `.crop-handle`: a 13 px square, and 10 px around it that
  // still takes the pointer; the edges' handles are 26 by 6.
  static const _corner = 13.0, _edgeLong = 26.0, _edgeShort = 6.0, _reach = 10.0;

  /// The crop while a drag moves it, before the edit has it.
  List<Offset>? _draft;
  _Drag? _drag;
  CropGrip? _hover;

  EditorModel get editor => widget.editor;

  /// What the crop is drawn on: a drag on another photograph or geometry is let go.
  String get _key {
    final e = editor.edit;
    return jsonEncode([
      editor.active?.handle, e['crop'], e['cropShape'], e['ratio'], e['rotation'], e['flip'],
      e['straighten'], e['perspectiveV'], e['perspectiveH'],
    ]);
  }

  List<Offset> get _points => _draft ?? editor.crop.points;

  Offset _toView(Offset p) => Offset(CropOverlay.margin + p.dx * widget.photo.width,
      CropOverlay.margin + p.dy * widget.photo.height);

  Offset _toCrop(Offset local) => Offset((local.dx - CropOverlay.margin) / widget.photo.width,
      (local.dy - CropOverlay.margin) / widget.photo.height);

  /// The handles' centres in the overlay, corners first, then the rectangle's edges.
  List<(CropGrip, Offset)> _handles(List<Offset> p) => [
        for (var i = 0; i < 4; i++) (CropGrip.values[i], _toView(p[i])),
        if (editor.crop.shape == 'rectangle') ...[
          (CropGrip.top, _toView(Offset.lerp(p[0], p[1], .5)!)),
          (CropGrip.right, _toView(Offset.lerp(p[1], p[2], .5)!)),
          (CropGrip.bottom, _toView(Offset.lerp(p[3], p[2], .5)!)),
          (CropGrip.left, _toView(Offset.lerp(p[0], p[3], .5)!)),
        ],
      ];

  static Size _handleSize(CropGrip grip) => switch (grip) {
        CropGrip.top || CropGrip.bottom => const Size(_edgeLong, _edgeShort),
        CropGrip.left || CropGrip.right => const Size(_edgeShort, _edgeLong),
        _ => const Size(_corner, _corner),
      };

  /// What is under `local`: the nearest handle within reach, else the inside of the crop.
  CropGrip? _gripAt(Offset local) {
    final p = _points;
    CropGrip? best;
    var nearest = double.infinity;
    for (final (grip, centre) in _handles(p)) {
      final size = _handleSize(grip);
      final d = local - centre;
      if (d.dx.abs() > size.width / 2 + _reach || d.dy.abs() > size.height / 2 + _reach) continue;
      if (d.distance < nearest) (best, nearest) = (grip, d.distance);
    }
    if (best != null) return best;
    final path = Path()..addPolygon([for (final v in p) _toView(v)], true);
    return path.contains(local) ? CropGrip.move : null;
  }

  /// The handles' centres in the window, for the driver.
  List<Offset> handlesInWindow() {
    final box = context.findRenderObject() as RenderBox;
    return [for (final (_, centre) in _handles(_points)) box.localToGlobal(centre)];
  }

  void _down(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton || _drag != null) return;
    final grip = _gripAt(event.localPosition);
    if (grip == null) return;
    final points = editor.crop.points;
    _drag = _Drag(grip, event.pointer, _key, _toCrop(event.localPosition), points);
    setState(() => _draft = points);
  }

  void _move(PointerMoveEvent event) {
    final drag = _drag;
    if (drag == null || drag.pointer != event.pointer) return;
    if (drag.key != _key) return _cancel();
    final point = _toCrop(event.localPosition);
    final crop = editor.crop;
    final next = drag.grip == CropGrip.move
        ? moveCrop(drag.points, point.dx - drag.start.dx, point.dy - drag.start.dy)
        : resizeCrop(drag.points, drag.grip, point,
            shape: crop.shape,
            locked: crop.ratio != 'free',
            minimum: Size((44 / widget.photo.width).clamp(0, .25),
                (44 / widget.photo.height).clamp(0, .25)));
    drag.latest = next;
    setState(() => _draft = next);
  }

  void _up(PointerUpEvent event) {
    final drag = _drag;
    if (drag == null || drag.pointer != event.pointer) return;
    _drag = null;
    final latest = drag.latest;
    setState(() => _draft = null);
    if (latest != null && drag.key == _key) editor.crop.setCrop(latest);
  }

  void _cancel([PointerCancelEvent? _]) => setState(() {
        _drag = null;
        _draft = null;
      });

  MouseCursor get _cursor => switch (_drag?.grip ?? _hover) {
        CropGrip.top || CropGrip.bottom => SystemMouseCursors.resizeUpDown,
        CropGrip.left || CropGrip.right => SystemMouseCursors.resizeLeftRight,
        CropGrip.move => SystemMouseCursors.move,
        null => MouseCursor.defer,
        _ => SystemMouseCursors.precise,
      };

  @override
  Widget build(BuildContext context) {
    final points = _points;
    final palette = Palette.of(context);
    return MouseRegion(
      cursor: _cursor,
      onHover: (e) {
        final grip = _gripAt(e.localPosition);
        if (grip != _hover) setState(() => _hover = grip);
      },
      onExit: (_) => setState(() => _hover = null),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: TweenAnimationBuilder<double>(
          // The thirds show while the crop moves (CropOverlay.css `.crop-thirds`).
          tween: Tween(end: _drag != null ? 1 : 0),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          builder: (context, thirds, _) => CustomPaint(
            size: Size.infinite,
            painter: _CropPainter(
              frame: Rect.fromLTWH(
                  CropOverlay.margin, CropOverlay.margin, widget.photo.width, widget.photo.height),
              quad: [for (final p in points) _toView(p)],
              handles: [
                for (final (grip, centre) in _handles(points))
                  Rect.fromCenter(
                      center: centre,
                      width: _handleSize(grip).width,
                      height: _handleSize(grip).height),
              ],
              rectangle: editor.crop.shape == 'rectangle',
              thirds: thirds,
              accent: palette.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _Drag {
  _Drag(this.grip, this.pointer, this.key, this.start, this.points);
  final CropGrip grip;
  final int pointer;
  final String key;
  final Offset start;
  final List<Offset> points;
  List<Offset>? latest;
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.frame,
    required this.quad,
    required this.handles,
    required this.rectangle,
    required this.thirds,
    required this.accent,
  });

  final Rect frame;
  final List<Offset> quad;
  final List<Rect> handles;
  final bool rectangle;
  final double thirds;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Path()..addPolygon(quad, true);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(frame)
        ..addPath(outline, Offset.zero),
      Paint()..color = const Color(0x88000000),
    );
    if (rectangle && thirds > 0) {
      final lines = Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: .6 * thirds)
        ..strokeWidth = .75;
      final (a, b) = (quad[0], quad[2]);
      for (final t in const [1 / 3, 2 / 3]) {
        final x = a.dx + t * (b.dx - a.dx), y = a.dy + t * (b.dy - a.dy);
        canvas.drawLine(Offset(x, a.dy), Offset(x, b.dy), lines);
        canvas.drawLine(Offset(a.dx, y), Offset(b.dx, y), lines);
      }
    }
    canvas.drawPath(
      outline,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final shadow = Paint()
      ..color = const Color(0x88000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    final fill = Paint()..color = accent;
    final border = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final h in handles) {
      final box = RRect.fromRectAndRadius(h, const Radius.circular(2));
      canvas.drawRRect(box.shift(const Offset(0, 1)), shadow);
      canvas.drawRRect(box, fill);
      canvas.drawRRect(box.deflate(1), border);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.frame != frame ||
      old.thirds != thirds ||
      old.accent != accent ||
      old.rectangle != rectangle ||
      !_same(old.quad, quad);

  static bool _same(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
