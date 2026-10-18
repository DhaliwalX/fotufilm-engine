// What the viewer is doing: the photograph's name, the shown develop's size and time, and the
// backend that developed it, announced to assistive technology rather than drawn. And the toolbar's
// pixel readout: the photograph's kind and megapixels, with the camera profile a RAW was read with.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

/// The status line's three parts: the name, what is happening, and the backend.
(String, String, String) viewerStatus(EditorModel editor) {
  final doc = editor.active;
  final renderer = editor.renderer;
  final shown = renderer?.lastPreview;
  final name = doc?.name ?? 'No photo open';
  String status;
  if (editor.status != null) {
    status = editor.status!;
  } else if (doc != null && (renderer?.busy ?? false)) {
    status = editor.error != null
        ? 'Preview unavailable'
        : doc.history.group != null
            ? 'Waiting for adjustments to settle before full-detail preview'
            : 'Waiting for the next display frame';
  } else if (shown != null && doc != null) {
    final elapsed = (shown['elapsed'] as num?)?.toDouble() ?? 0;
    status = '${shown['width']} × ${shown['height']} · ${elapsed.toStringAsFixed(0)} ms';
  } else {
    status = '';
  }
  final backend = switch (shown?['backend']) {
    'webgpu' => 'WebGPU',
    'Halide/Metal' => 'Metal',
    null => '',
    _ => 'CPU',
  };
  return (name, status, backend);
}

/// The status, for a screen reader only; it announces each change.
class ViewerStatus extends StatelessWidget {
  const ViewerStatus({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final (name, status, backend) = viewerStatus(editor);
    return Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: Semantics(
        container: true,
        liveRegion: true,
        label: [name, status, backend].where((s) => s.isNotEmpty).join(', '),
        child: const SizedBox.shrink(),
      ),
    );
  }
}

/// The photograph's kind as the readout prefixes it: Video, HDR, a deep format's bit depth, a
/// linear EXR or RAW.
String pixelKind(PhotoDocument doc) {
  final d = doc.descriptor;
  if (d['video'] != null) return 'Video · ';
  if (d['hdr'] != null) return 'HDR · ';
  if (d['deep'] case {'format': final format, 'bitDepth': final depth}) {
    return '$format · $depth-bit · ';
  }
  if (d['linear'] == true) return 'EXR · linear · ';
  if (doc.raw || d['raw'] != null) return 'RAW · ';
  return '';
}

/// The camera spectral profile a RAW was read with, for the readout's tooltip.
String? cameraProfileTip(PhotoDocument doc) {
  final raw = doc.descriptor['raw'];
  if (raw is! Map) return null;
  final profile = raw['profile'];
  if (profile is Map) {
    return 'Camera spectral profile: ${profile['name']} · estimated '
        '${(profile['kelvin'] as num).round()} K';
  }
  return 'RAW decoder color · no matching camera spectral correction';
}

/// The toolbar's readout: "HDR · 24.2 MP", hidden in a window too narrow for it.
class PixelReadout extends StatelessWidget {
  const PixelReadout({super.key, required this.doc});
  final PhotoDocument? doc;

  @override
  Widget build(BuildContext context) {
    final doc = this.doc;
    final text = doc == null
        ? ''
        : '${pixelKind(doc)}${(doc.width * doc.height / 1e6).toStringAsFixed(1)} MP';
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 46),
        child: HoverTip(
          message: doc == null ? null : cameraProfileTip(doc),
          child: Text(text,
              style: editorText(context,
                  size: TextSizes.label, color: Palette.of(context).muted)),
        ),
      ),
    );
  }
}
