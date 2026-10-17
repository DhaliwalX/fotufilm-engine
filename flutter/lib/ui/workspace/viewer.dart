// The viewer (web/src/editor/EditorViewer.jsx, ImageCanvas.jsx, styles/viewer.css): the
// photograph on the canvas colour, fitted or magnified, the original while Space is held, and the
// viewer's overlays, with the photo strip under it.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../theme/theme.dart';
import 'histogram_panel.dart';
import 'library/library_handoff.dart';
import 'overlays.dart';
import 'photo_strip.dart';
import 'picture.dart';
import 'viewer_tools.dart';

class EditorViewer extends StatelessWidget {
  const EditorViewer({
    super.key,
    required this.editor,
    required this.onOpen,
    required this.dropping,
  });

  final EditorModel editor;
  final VoidCallback onOpen;
  final bool dropping;

  @override
  Widget build(BuildContext context) {
    final doc = editor.active;
    return ColoredBox(
      color: Palette.of(context).canvas,
      child: Column(children: [
        Expanded(
          child: LayoutBuilder(key: libraryViewerKey, builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final size = constraints.biggest;
            // The view's size feeds what gets developed; layout may not notify, so after it.
            WidgetsBinding.instance.addPostFrameCallback((_) => editor.updateViewer(size, dpr));
            return Stack(children: [
              Positioned.fill(
                child: doc == null
                    ? EmptyCanvas(onOpen: onOpen, ready: editor.ready, error: editor.startupError)
                    : PhotoCanvas(editor: editor, doc: doc),
              ),
              if (editor.comparing) const OriginalBadge(),
              if (editor.status != null) StatusPill(text: editor.status!),
              if (editor.error != null)
                ErrorBanner(text: editor.error!, onClose: editor.dismissError),
              if (editor.histogramOpen && doc != null)
                HistogramPanel(data: editor.histogram, onClose: editor.toggleHistogram),
              if (dropping) const DropOverlay(),
            ]);
          }),
        ),
        // Shown once it holds more than one photo.
        PhotoStrip(editor: editor),
      ]),
    );
  }
}

/// The photograph: the presenter's preview layer (or a decoded picture), and over it, while
/// magnified, the detail layer at the screen's resolution for the part on show.
class PhotoCanvas extends StatefulWidget {
  const PhotoCanvas({super.key, required this.editor, required this.doc});
  final EditorModel editor;
  final PhotoDocument doc;

  @override
  State<PhotoCanvas> createState() => _PhotoCanvasState();
}

class _PhotoCanvasState extends State<PhotoCanvas> {
  double? _pinchStart;

  EditorModel get editor => widget.editor;

  void _scroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      editor.zoomAround(editor.scale * math.exp(-event.scrollDelta.dy / 300), event.localPosition);
    } else {
      editor.panBy(-event.scrollDelta);
    }
  }

  void _pinch(PointerPanZoomUpdateEvent event) {
    if ((event.scale - 1).abs() > 0.01 && _pinchStart != null) {
      editor.zoomAround(_pinchStart! * event.scale, event.localPosition);
    } else {
      editor.panBy(event.panDelta);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final photo = editor.photoSize;
    final rect = editor.view.photoRect(photo);
    final detail = _detail(photo);
    return Listener(
      onPointerSignal: _scroll,
      onPointerPanZoomStart: (_) => _pinchStart = editor.scale,
      onPointerPanZoomUpdate: _pinch,
      onPointerPanZoomEnd: (_) => _pinchStart = null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: editor.zoomed ? (d) => editor.panBy(d.delta) : null,
        onDoubleTapDown: (d) =>
            editor.zoomed ? editor.setZoom(null) : editor.zoomAround(1, d.localPosition),
        onDoubleTap: () {},
        child: ClipRect(
          child: Stack(children: [
            Positioned.fromRect(
              rect: rect,
              child: DecoratedBox(
                decoration: const BoxDecoration(boxShadow: [
                  BoxShadow(color: Color(0x18000000), blurRadius: 12, offset: Offset(0, 2)),
                ]),
                child: _preview(doc),
              ),
            ),
            if (detail != null)
              Positioned.fromRect(rect: detail.region!.shift(rect.topLeft), child: _layer('detail')),
            ...viewerToolOverlays(editor, rect),
          ]),
        ),
      ),
    );
  }

  /// The detail frame, when it is for the view on show.
  PresentedFrame? _detail(Size photo) {
    final detail = widget.doc.detail;
    final renderer = editor.renderer;
    if (detail == null || renderer == null || !editor.view.magnified(photo)) return null;
    if (detail.scale != editor.scale || !renderer.shows('detail', widget.doc)) return null;
    if (editor.comparing && !renderer.shows('detail.original', widget.doc)) return null;
    return detail;
  }

  Widget _preview(PhotoDocument doc) {
    final renderer = editor.renderer;
    final layer = editor.comparing ? 'preview.original' : 'preview';
    if (doc.preview != null && renderer != null && renderer.shows(layer, doc)) {
      return _layer('preview');
    }
    final image = editor.comparing
        ? (doc.originalImage ?? doc.importPicture)
        : (doc.previewImage ?? doc.importPicture);
    if (image == null) return ColoredBox(color: Palette.of(context).panel);
    return EnginePicture(image);
  }

  /// A presenter layer, or its original while comparing.
  Widget _layer(String name) {
    final presenter = editor.presenter!;
    return PresentedLayer(
      texture: presenter.textures[editor.comparing ? '$name.original' : name]!,
      swapRedBlue: presenter.swapRedBlue,
      converted: presenter.convertsColour,
    );
  }
}
