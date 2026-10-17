// The crop tool's state and actions (web/src/CropControls.jsx, editor/CropInspector.jsx and
// editor/usePreviewState.js). While it is open the viewer shows the whole oriented frame, developed
// with `cropMode` and the crop left out, with the crop drawn over it; Done shows the cropped
// photograph again.
import 'dart:ui';

import 'crop_geometry.dart';
import 'edit.dart';
import 'editor.dart';

class CropTool {
  CropTool(this.editor) {
    editor.renderOptionSources.add(_options);
    editor.addListener(_follow);
  }

  final EditorModel editor;

  /// The aspect picker's choices (CropControls.jsx `aspects`).
  static const aspects = ['free', 'original', '1:1', '4:5', '3:2', '16:9'];

  /// Whether the tool is open, so the viewer shows the uncropped frame (usePreviewState.js
  /// `cropMode`): the crop panel, with the inspector showing it.
  bool get showing => editor.panel == Panel.crop && editor.inspectorOpen;

  Json get _edit => editor.edit;
  List<Offset> get points => cropPoints(_edit['crop']);
  String get shape => _edit['cropShape'] as String? ?? 'rectangle';
  String get ratio => _edit['ratio'] as String? ?? 'free';

  /// The aspect picker's choices, with a ratio an older editor saved.
  List<String> get ratioChoices => aspects.contains(ratio) ? aspects : [...aspects, ratio];

  /// The frame the crop is drawn on: the photograph as rotated, in its own pixels.
  Size get frame {
    final doc = editor.active;
    return doc == null ? Size.zero : orientedSize(doc.width, doc.height, _edit);
  }

  /// The cropped photograph's size in pixels, as the inspector reports it.
  Size get cropSize {
    final size = outputSize(points, frame);
    return Size(size.width.roundToDouble().clamp(1, double.infinity),
        size.height.roundToDouble().clamp(1, double.infinity));
  }

  /// The develops of the shown picture while the tool is open: the whole frame, cropless, so
  /// moving the crop never develops it again.
  Json _options(PhotoDocument doc) => !showing
      ? const <String, dynamic>{}
      : {
          'cropMode': true,
          'edit': copyEdit(doc.edit)
            ..['crop'] = fullCrop()
            ..['ratio'] = 'free',
        };

  /// Opening the tool fits the frame: it is cropped at the size it fits (ImageCanvas.jsx).
  bool _wasShowing = false;
  void _follow() {
    if (showing == _wasShowing) return;
    _wasShowing = showing;
    if (showing && editor.view.zoom != null) editor.setZoom(null);
  }

  // ── Actions ───────────────────────────────────────────────────────────────────────────────

  void toggle() {
    if (editor.active != null) editor.toggleTool(Panel.crop);
  }

  /// Leaves the tool for the tab it was opened from.
  void leave() {
    if (editor.panel == Panel.crop) editor.toggleTool(Panel.crop);
  }

  /// Done: the edit so far is one step, and the cropped photograph shows.
  void done() {
    editor.endEdit();
    leave();
  }

  /// A quarter turn left. A rectangle starts over on the turned frame; four corners turn with it.
  void rotateLeft() => editor.change({
        'rotation': (((_edit['rotation'] as num?) ?? 0).toInt() + 1) % 4,
        'ratio': 'free',
        'crop': shape == 'corners'
            ? cropJson(rotatedCrop(points, mirrored: _edit['flip'] == true))
            : fullCrop(),
      });

  void flip() => editor.change({
        'flip': _edit['flip'] != true,
        if (shape == 'corners') 'crop': cropJson(flippedCrop(points)),
      });

  /// Four-Corner Crop: each corner moves on its own, to correct a keystoned frame.
  void fourCorners() => editor.change({'cropShape': 'corners', 'ratio': 'free'});

  /// An aspect: the largest centred rectangle of it, turned to the frame.
  void setRatio(String next) {
    final frame = this.frame;
    editor.change({
      'ratio': next,
      'cropShape': 'rectangle',
      'crop': cropJson(cropForRatio(orientedRatio(next, frame.width, frame.height),
          frame.width, frame.height)),
    });
  }

  /// Straighten and perspective, one step a drag.
  void setGeometry(String key, double value) =>
      editor.patch({key: plainNumber(value)}, group: 'geometry-$key');

  /// The crop the overlay was let go at, as one step.
  void setCrop(List<Offset> next) => editor.change({'crop': cropJson(next)});

  /// Reset Crop: the whole frame, upright, unturned and unflipped.
  void reset() => editor.change({
        'rotation': 0,
        'flip': false,
        'crop': fullCrop(),
        'cropShape': 'rectangle',
        'ratio': 'free',
        'straighten': 0,
        'perspectiveV': 0,
        'perspectiveH': 0,
      });
}
