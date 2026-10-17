// The crop's geometry, as the web editor keeps it: a quadrilateral in unit coordinates of the
// oriented frame (web/src/editor-state.js `fullCrop`, `validCrop`, `rotatedCrop`, `flippedCrop`,
// `cropForRatio`), how the overlay moves and resizes it (web/src/crop-interaction.js), and the
// size the engine delivers for it (Sources/FotufilmHost/SceneGeometry.swift `snapped`, `sizes`).
import 'dart:math' as math;
import 'dart:ui';

import 'catalogue.dart';
import 'document.dart';

/// The whole frame, in the edit's own JSON (whole numbers, as `defaultEdit` writes it).
List<List<num>> fullCrop() => [
      [0, 0],
      [1, 0],
      [1, 1],
      [0, 1],
    ];

/// The edit's crop as points: top left, top right, bottom right, bottom left.
List<Offset> cropPoints(Object? crop) => [
      for (final p in (crop as List? ?? fullCrop()))
        Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];

/// Points as the edit's JSON. Whole values stay whole, so a crop dragged back to the frame's
/// edge reads as the untouched one.
List<List<num>> cropJson(List<Offset> points) => [
      for (final p in points) [_plain(p.dx), _plain(p.dy)],
    ];

num _plain(double v) => v == v.roundToDouble() ? v.round() : v;

/// A value for the edit's JSON, whole where it is whole (a slider reset to 0 is the default 0).
num plainNumber(double v) => _plain(v);

List<Offset> rectangleCrop(double left, double top, double right, double bottom) =>
    [Offset(left, top), Offset(right, top), Offset(right, bottom), Offset(left, bottom)];

bool isFullCrop(List<Offset> p) =>
    p.length == 4 &&
    p[0] == Offset.zero &&
    p[1] == const Offset(1, 0) &&
    p[2] == const Offset(1, 1) &&
    p[3] == const Offset(0, 1);

/// Four points inside the frame, turning the same way at every corner (a convex quadrilateral).
bool validCrop(List<Offset> p) {
  if (p.length != 4) return false;
  for (final v in p) {
    if (!v.dx.isFinite || !v.dy.isFinite || v.dx < 0 || v.dx > 1 || v.dy < 0 || v.dy > 1) {
      return false;
    }
  }
  for (var i = 0; i < 4; i++) {
    final a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4];
    if ((b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx) <= 0.0001) return false;
  }
  return true;
}

/// A four-corner crop carried through a quarter turn left, mirrored when the frame is flipped.
List<Offset> rotatedCrop(List<Offset> c, {bool mirrored = false}) => mirrored
    ? [for (final p in [c[3], c[0], c[1], c[2]]) Offset(1 - p.dy, p.dx)]
    : [for (final p in [c[1], c[2], c[3], c[0]]) Offset(p.dy, 1 - p.dx)];

/// A four-corner crop carried through a flip.
List<Offset> flippedCrop(List<Offset> c) =>
    [for (final p in [c[1], c[0], c[3], c[2]]) Offset(1 - p.dx, p.dy)];

/// A named aspect turned to the frame: 3:2 on a portrait frame is 2:3. Free and Original, and
/// ratios saved by older editors, stay as they are (CropControls.jsx `aspect`).
String orientedRatio(String ratio, double width, double height) {
  if (!const ['4:5', '3:2', '16:9'].contains(ratio)) return ratio;
  final [a, b] = ratio.split(':').map(int.parse).toList();
  final (short, long) = (math.min(a, b), math.max(a, b));
  return height > width ? '$short:$long' : '$long:$short';
}

/// The largest centred crop of `ratio` on a `width` x `height` frame.
List<Offset> cropForRatio(String ratio, double width, double height) {
  if (ratio == 'free' || ratio == 'original') return cropPoints(fullCrop());
  final [a, b] = ratio.split(':').map(double.parse).toList();
  final target = a / b, aspect = width / height;
  final w = math.min(1.0, target / aspect), h = math.min(1.0, aspect / target);
  return rectangleCrop((1 - w) / 2, (1 - h) / 2, (1 + w) / 2, (1 + h) / 2);
}

// ── The overlay's moves (web/src/crop-interaction.js) ─────────────────────────────────────────

/// What a pointer holds of the crop: a corner, an edge, or the whole of it.
enum CropGrip {
  topLeft,
  topRight,
  bottomRight,
  bottomLeft,
  top,
  right,
  bottom,
  left,
  move;

  /// The corner's index in the crop's points, for the four corners.
  int? get corner => index < 4 ? index : null;
}

/// The crop moved by (dx, dy), stopping at the frame's edges.
List<Offset> moveCrop(List<Offset> points, double dx, double dy) {
  final xs = points.map((p) => p.dx), ys = points.map((p) => p.dy);
  dx = _clamp(dx, -xs.reduce(math.min), 1 - xs.reduce(math.max));
  dy = _clamp(dy, -ys.reduce(math.min), 1 - ys.reduce(math.max));
  return [for (final p in points) p.translate(dx, dy)];
}

/// The crop with `grip` taken to `point`. A rectangle keeps its corners square and, `locked` to
/// its ratio, its proportions; it stays at least `minimum` across. A four-corner crop moves only
/// the corner held, and refuses a shape that folds over.
List<Offset> resizeCrop(
  List<Offset> points,
  CropGrip grip,
  Offset point, {
  required String shape,
  required bool locked,
  Size minimum = const Size(0.01, 0.01),
}) {
  final x = point.dx.clamp(0.0, 1.0), y = point.dy.clamp(0.0, 1.0);
  if (shape == 'corners') {
    final corner = grip.corner;
    if (corner == null) return points;
    final next = [...points]..[corner] = Offset(x, y);
    return validCrop(next) ? next : points;
  }
  var (left, top) = (points[0].dx, points[0].dy);
  var (right, bottom) = (points[2].dx, points[2].dy);
  final ratio = (right - left) / (bottom - top);
  final corner = grip.corner;
  if (corner != null) {
    final anchor = points[(corner + 2) % 4];
    final (ax, ay) = (anchor.dx, anchor.dy);
    final sx = corner == 0 || corner == 3 ? -1 : 1, sy = corner < 2 ? -1 : 1;
    final roomX = sx < 0 ? ax : 1 - ax, roomY = sy < 0 ? ay : 1 - ay;
    var w = _clamp((x - ax) * sx, minimum.width, roomX);
    var h = _clamp((y - ay) * sy, minimum.height, roomY);
    if (locked) {
      w = [math.max(w, h * ratio), roomX, roomY * ratio].reduce(math.min);
      h = w / ratio;
    }
    left = sx < 0 ? ax - w : ax;
    right = sx < 0 ? ax : ax + w;
    top = sy < 0 ? ay - h : ay;
    bottom = sy < 0 ? ay : ay + h;
  } else if (grip == CropGrip.left || grip == CropGrip.right) {
    if (grip == CropGrip.left) {
      left = _clamp(x, 0, right - minimum.width);
    } else {
      right = _clamp(x, left + minimum.width, 1);
    }
    if (locked) {
      final cy = (top + bottom) / 2;
      final w = math.min(right - left, 2 * math.min(cy, 1 - cy) * ratio);
      if (grip == CropGrip.left) {
        left = right - w;
      } else {
        right = left + w;
      }
      top = cy - w / ratio / 2;
      bottom = cy + w / ratio / 2;
    }
  } else if (grip == CropGrip.top || grip == CropGrip.bottom) {
    if (grip == CropGrip.top) {
      top = _clamp(y, 0, bottom - minimum.height);
    } else {
      bottom = _clamp(y, top + minimum.height, 1);
    }
    if (locked) {
      final cx = (left + right) / 2;
      final h = math.min(bottom - top, 2 * math.min(cx, 1 - cx) / ratio);
      if (grip == CropGrip.top) {
        top = bottom - h;
      } else {
        bottom = top + h;
      }
      left = cx - h * ratio / 2;
      right = cx + h * ratio / 2;
    }
  } else {
    return points;
  }
  final next = rectangleCrop(left, top, right, bottom);
  return validCrop(next) ? next : points;
}

/// JavaScript's clamp, which takes the upper bound when the bounds cross.
double _clamp(double v, double lo, double hi) => math.max(lo, math.min(hi, v));

// ── Sizes ─────────────────────────────────────────────────────────────────────────────────────

/// The photograph's frame as the edit turns it: a quarter turn swaps its sides.
Size orientedSize(int width, int height, Json edit) => ((edit['rotation'] as num?) ?? 0) % 2 == 0
    ? Size(width.toDouble(), height.toDouble())
    : Size(height.toDouble(), width.toDouble());

/// The crop's size in the oriented frame's pixels (web/src/geometry.js `outputSize`).
Size outputSize(List<Offset> p, Size frame) {
  double distance(Offset a, Offset b) =>
      math.sqrt(math.pow((a.dx - b.dx) * frame.width, 2) + math.pow((a.dy - b.dy) * frame.height, 2));
  return Size(
    (distance(p[0], p[1]) + distance(p[3], p[2])) / 2,
    (distance(p[0], p[3]) + distance(p[1], p[2])) / 2,
  );
}

/// The crop the engine cuts: an upright rectangle on an unstraightened frame is moved out to
/// whole pixels (SceneGeometry.swift `snapped`); any other crop is sampled as drawn.
List<Offset> snappedCrop(List<Offset> crop, Json edit, Size frame) {
  final straightened = (((edit['straighten'] as num?) ?? 0).abs()) > 0.001;
  final perspective = (((edit['perspectiveV'] as num?) ?? 0).abs()) > 0.001 ||
      (((edit['perspectiveH'] as num?) ?? 0).abs()) > 0.001;
  final (left, top, right, bottom) = (crop[0].dx, crop[0].dy, crop[2].dx, crop[2].dy);
  if (isFullCrop(crop) || straightened || perspective ||
      crop[1] != Offset(right, top) || crop[3] != Offset(left, bottom) ||
      left >= right || top >= bottom) {
    return crop;
  }
  (double, double) outward(double low, double high, double size) => (
        math.max(0.0, (low * size + 1e-6).floorToDouble()) / size,
        math.min(size, (high * size - 1e-6).ceilToDouble()) / size,
      );
  final (x0, x1) = outward(left, right, frame.width);
  final (y0, y1) = outward(top, bottom, frame.height);
  return rectangleCrop(x0, y0, x1, y1);
}

/// The full-size picture the engine delivers for `edit` on a `width` x `height` photograph: the
/// cropped photograph, or with `uncropped` the crop tool's whole oriented frame
/// (SceneGeometry.swift `sizes`, which straightening and perspective leave the same size).
Size deliveredSize(int width, int height, Json edit, {bool uncropped = false}) {
  final frame = orientedSize(width, height, edit);
  if (uncropped) return frame;
  final crop = snappedCrop(cropPoints(edit['crop']), edit, frame);
  final size = outputSize(crop, frame);
  return Size(math.max(1, size.width.roundToDouble()), math.max(1, size.height.roundToDouble()));
}

/// The full-size picture a develop of `doc` with the viewer's `options` delivers: the edit they
/// carry (the crop tool's uncropped one) or the document's own.
Size developedSize(PhotoDocument doc, Json options) => deliveredSize(
      doc.width,
      doc.height,
      (options['edit'] as Json?) ?? doc.edit,
      uncropped: options['cropMode'] == true,
    );
