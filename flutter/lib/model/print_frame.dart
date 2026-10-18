// Print frames (web/src/PrintFrameControls.jsx, usePrintFrame.js, print-frame.js): the frames the
// film and medium offer, the engine's plan for the chosen one, and the frame the finished picture
// develops in (backend/desktop/session.js `renderRequest`). The engine draws the frame itself.
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
    'viewingKelvin': printLights.where((c) => c['id'] == light).firstOrNull?['value'],
    'width': width,
    'height': height,
  };
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
  /// the plan's placement is the framed picture's (usePrintFrame.js).
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
