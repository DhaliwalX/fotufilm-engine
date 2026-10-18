// The selective tool's sampling over the viewer: a crosshair over the canvas, and a press on the
// photograph samples it there. A press beside the photograph does nothing.
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';

class SamplingOverlay extends StatelessWidget {
  const SamplingOverlay({super.key, required this.editor, required this.photo});
  final EditorModel editor;

  /// The picture's rectangle in the viewer.
  final Rect photo;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            final at = event.localPosition;
            if (event.buttons & kPrimaryButton == 0 || !photo.contains(at)) return;
            editor.selective.sample([
              ((at.dx - photo.left) / photo.width).clamp(0, 1).toDouble(),
              ((at.dy - photo.top) / photo.height).clamp(0, 1).toDouble(),
            ]);
          },
        ),
      );
}
