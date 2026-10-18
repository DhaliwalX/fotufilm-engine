// Where the photograph sits in the viewer: fitted or magnified, and panned.
import 'dart:math' as math;
import 'dart:ui';

class ViewState {
  /// How far the fitted photograph stays from the viewer's edges.
  static const fitInset = 16.0;

  /// The viewer's size in logical pixels and the screen's pixel ratio.
  Size viewer = Size.zero;
  double devicePixelRatio = 2;

  /// Magnification against the photograph's own pixels; null fits it.
  double? zoom;

  /// Where a magnified photograph's centre is, against the viewer's centre.
  Offset pan = Offset.zero;

  static const steps = [0.0625, 0.125, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 8.0];
  static const maxZoom = 8.0;

  double fitScale(Size photo) {
    if (viewer.isEmpty || photo.isEmpty) return 1;
    const inset = fitInset;
    return math
        .min((viewer.width - inset * 2) / photo.width, (viewer.height - inset * 2) / photo.height)
        .clamp(0.01, 64.0);
  }

  double scale(Size photo) => zoom ?? fitScale(photo);

  /// The photograph's rectangle in the viewer.
  Rect photoRect(Size photo) {
    final s = scale(photo);
    return Rect.fromCenter(
        center: viewer.center(Offset.zero) + pan, width: photo.width * s, height: photo.height * s);
  }

  /// Keeps a magnified photograph from leaving the viewer.
  void clampPan(Size photo) {
    if (zoom == null) {
      pan = Offset.zero;
      return;
    }
    final s = scale(photo);
    final dx = math.max(0.0, (photo.width * s - viewer.width) / 2 + 40);
    final dy = math.max(0.0, (photo.height * s - viewer.height) / 2 + 40);
    pan = Offset(pan.dx.clamp(-dx, dx), pan.dy.clamp(-dy, dy));
  }

  /// Zooms to `next`, keeping the point at `focal` (viewer coordinates) still.
  void zoomAround(Size photo, double next, Offset focal) {
    final current = scale(photo);
    final fit = fitScale(photo);
    next = next.clamp(math.min(fit, steps.first), maxZoom);
    final centre = viewer.center(Offset.zero);
    pan = (focal - centre) - ((focal - centre) - pan) * (next / current);
    zoom = (next - fit).abs() < 1e-3 ? null : next;
    clampPan(photo);
  }

  /// Whether the photograph is magnified past the viewer, so a detail layer pays.
  bool magnified(Size photo) {
    final rect = photoRect(photo);
    return zoom != null && (rect.width > viewer.width || rect.height > viewer.height);
  }

  /// The visible part of the photograph, in its logical pixels at the current scale.
  Rect visibleRegion(Size photo) {
    final rect = photoRect(photo);
    final visible = rect.intersect(Offset.zero & viewer);
    return visible.shift(-rect.topLeft);
  }
}
