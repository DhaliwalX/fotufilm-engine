// Print frames (web/src/print-frame.js): the frames the film and medium offer, the engine's plan
// for the chosen one, and the frame the finished picture develops in. The engine draws
// the frame itself.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'crop_geometry.dart';
import 'editor.dart';

/// What the engine plans a frame from (print-frame.js `frameRequest`): `printLight`'s menu value
/// is the light the print is viewed under.
Json frameRequest(Json edit, List<Json> printLights, {int width = 1, int height = 1}) {
  final light = ((edit['profile'] as Map?) ?? const {})['printLight'];
  return {
    'kind': 'print-frame',
    'stock': edit['stock'],
    'frame': edit['printFrame'] ?? 'none',
    'format': edit['format'],
    'medium': edit['medium'],
    'frameNumber': edit['printFrameNumber'] ?? 1,
    'edgePrinting': edit['printFrameEdgePrinting'] ?? true,
    'framing': edit['printFrameFraming'] ?? const [0, 0],
    'frames': edit['printFrameCount'] ?? 1,
    'camera': edit['printFrameCamera'] ?? 'panoramic',
    'viewingKelvin': printLights.where((c) => c['id'] == light).firstOrNull?['value'],
    'width': width,
    'height': height,
  };
}

/// A film border's framing after the picture is dragged `drag` screen points from `start`, where
/// `plan`'s framed picture is shown `shown` points wide: the photograph follows the pointer under
/// the aperture, as far as its edges.
List<double> framingAfterDrag(List<double> start, ui.Offset drag, Map plan, double shown) {
  double n(Map m, String key) => (m[key] as num).toDouble();
  final crop = plan['crop'] as Map, fraction = plan['cropFraction'] as Map;
  final size = (plan['placement'] as Map)['size'] as Map;
  // Screen points to photograph pixels; the crop is the photograph's pixels inside the frame.
  final pixels = drag * (n(size, 'width') / shown);
  double moved(double from, double by, double cropped, double share) {
    final spare = cropped / share - cropped;
    return spare < 1 ? from : (from - 2 * by / spare).clamp(-1.0, 1.0);
  }

  return [
    moved(start[0], pixels.dx, n(crop, 'width'), n(fraction, 'width')),
    moved(start[1], pixels.dy, n(crop, 'height'), n(fraction, 'height')),
  ];
}

/// Whether an edit asks for a frame around its picture.
bool framesPicture(Json edit) => (edit['printFrame'] ?? 'none') != 'none';

class PrintFrame extends ChangeNotifier {
  PrintFrame(this.editor) {
    editor.renderOptionSources.add(_options);
  }

  final EditorModel editor;

  List<Json> get _printLights =>
      ((editor.catalogue.profileMenus['printLight'] as List?) ?? const []).cast<Json>();

  /// The frame request for `doc`'s finished picture: only the photograph as it will print, never
  /// the crop tool's uncropped frame or a pipeline stage (and small pictures never ask).
  Json _options(PhotoDocument doc) {
    if (!framesPicture(doc.edit)) return const {};
    final others = {
      for (final source in editor.renderOptionSources)
        if (source != _options) ...source(doc),
    };
    if (others['cropMode'] == true || others['stage'] != null) return const {};
    return {'printFrame': request(doc.edit)};
  }

  /// The frame an export of `edit` is developed in, or null.
  Json? request(Json edit) => framesPicture(edit) ? frameRequest(edit, _printLights) : null;

  // ── The plan ──────────────────────────────────────────────────────────────────────────────

  String? _key;
  Json? _plan;
  String? _error;

  /// The plan for the shown photograph's frame (`available`, `configuration`, `placement`,
  /// `renderMedium`), once the engine has answered for the current edit.
  Json? get plan => _current ? _plan : null;
  String? get error => _current ? _error : null;
  bool get pending => _requestKey != null && !_current;
  bool get _current => _key != null && _key == _requestKey;

  /// The request the shown photograph's frame is planned with, at the finished picture's size, so
  /// the plan's placement is the framed picture's.
  String? get _requestKey {
    final doc = editor.active;
    if (doc == null) return null;
    // The finished picture: cropped, straightened and turned.
    final size = developedSize(doc, const {});
    return jsonEncode(frameRequest(doc.edit, _printLights,
        width: size.width.round(), height: size.height.round()));
  }

  /// Asks the engine for the plan when the edit's frame request changed.
  void follow() {
    final key = _requestKey;
    final engine = editor.engine;
    if (key == null || engine == null || key == _pendingKey || key == _key) return;
    _pendingKey = key;
    engine.call('printFrame', jsonDecode(key) as Json).then((answer) {
      if (_pendingKey != key) return;
      _settle(key, answer.json, null);
    }, onError: (Object e) {
      if (_pendingKey != key) return;
      _settle(key, null, '$e');
    });
  }

  String? _pendingKey;

  void _settle(String key, Json? plan, String? error) {
    _key = key;
    _plan = plan;
    _error = error;
    _pendingKey = null;
    notifyListeners();
    // The framed picture is a different shape: the viewer lays it out again.
    editor.rendered();
  }

  // ── Framing ───────────────────────────────────────────────────────────────────────────────

  /// Whether the shown frame shows only part of the photograph — a film border on a photograph
  /// of another shape — so a drag on the picture moves the part it shows.
  bool get framable {
    final doc = editor.active, plan = this.plan;
    return doc != null && plan?['crop'] != null && plan?['cropFraction'] != null &&
        (plan?['configuration'] as Map?)?['frame'] == doc.edit['printFrame'];
  }

  List<double>? _framingStart;
  ui.Offset _framingDrag = ui.Offset.zero;

  /// A drag on the framed picture begins: the framing it moves from.
  void beginFraming() {
    final framing = (editor.edit['printFrameFraming'] as List?) ?? const [0, 0];
    _framingStart = [for (final v in framing) (v as num).toDouble()];
    _framingDrag = ui.Offset.zero;
  }

  /// The picture dragged by `delta` on the screen, where the framed picture is `shown` wide: the
  /// photograph moves under the aperture with the pointer, as far as its edges.
  void dragFraming(ui.Offset delta, ui.Size shown) {
    final start = _framingStart, plan = this.plan;
    if (start == null || plan == null || !framable || shown.width <= 0) return;
    _framingDrag += delta;
    editor.patch({'printFrameFraming': framingAfterDrag(start, _framingDrag, plan, shown.width)},
        group: 'printFrameFraming');
  }

  /// The drag ends, and the picture develops at full size.
  void endFraming() {
    if (_framingStart == null) return;
    _framingStart = null;
    editor.endEdit();
  }

  /// The shown picture's size: `photo` itself, or with a frame around the finished picture, the
  /// framed picture's.
  ui.Size framed(ui.Size photo) {
    final doc = editor.active;
    if (doc == null || !framesPicture(doc.edit) || _options(doc).isEmpty) return photo;
    follow();
    final size = (plan?['placement'] as Map?)?['size'] as Map?;
    final configuration = plan?['configuration'] as Map?;
    if (size == null || configuration?['frame'] == 'none') return photo;
    return ui.Size((size['width'] as num).toDouble(), (size['height'] as num).toDouble());
  }
}
