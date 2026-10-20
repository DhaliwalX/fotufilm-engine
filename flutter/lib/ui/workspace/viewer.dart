// The viewer: the photograph on the canvas colour, fitted or magnified, the original while Space or
// a press on it is held, and the viewer's overlays, with the photo strip under it.
import 'dart:async';
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
import 'startup_progress.dart';
import 'video_controls.dart';
import 'viewer_status.dart';
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
      // A movie's keys while the viewer has the keyboard (video_controls.dart).
      child: VideoKeys(editor: editor, child: Column(children: [
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
              if (editor.status != null)
                StatusPill(
                    text: editor.status!, onCancel: editor.importing ? editor.cancelImport : null),
              // What Auto Adjust is doing.
              if (editor.status == null && editor.auto.status != null)
                StatusPill(text: editor.auto.status!),
              if (editor.error != null)
                ErrorBanner(
                  text: editor.error!,
                  onClose: editor.dismissError,
                  onRetry: editor.canRetry ? editor.retry : null,
                ),
              if (editor.histogramOpen && doc != null)
                HistogramPanel(
                  data: editor.histogram,
                  onClose: editor.toggleHistogram,
                  labels: editor.catalogue.module['HISTOGRAM'] as Json?,
                ),
              if (dropping) const DropOverlay(),
              StartupProgress(
                  key: const ValueKey('startup'),
                  progress: editor.startup,
                  compact: editor.layout.compact),
              ViewerStatus(editor: editor),
            ]);
          }),
        ),
        // A movie's transport.
        if (doc != null && doc.isMovie) VideoControls(editor: editor, doc: doc),
        // Shown once it holds more than one photo.
        PhotoStrip(editor: editor),
      ])),
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

  // ── Press to compare ──────────────────────────────────────────────────────────────────────

  /// Where each pointer on the photograph went down.
  final Map<int, Offset> _pressed = {};
  Timer? _hold;

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  /// A press shows the original at any zoom, a touch once it has been held a moment; a drag or a
  /// second finger ends it. The crop and the samplers take the pointer for themselves.
  void _pressDown(PointerDownEvent event) {
    final touch = event.kind == PointerDeviceKind.touch;
    if (!touch && event.buttons != kPrimaryButton) return;
    if (editor.crop.showing || editor.selective.sampling || editor.negatives.sampling) return;
    _pressed[event.pointer] = event.localPosition;
    _hold?.cancel();
    if (_pressed.length > 1) {
      editor.setComparing(false);
    } else if (touch || editor.printFrame.framable) {
      // On a film border that crops the photograph a press may be the start of a drag.
      _hold = Timer(const Duration(milliseconds: 180), () => editor.setComparing(true));
    } else {
      editor.setComparing(true);
    }
  }

  void _pressMove(PointerMoveEvent event) {
    final start = _pressed[event.pointer];
    if (start == null || (event.localPosition - start).distance <= 6) return;
    _hold?.cancel();
    editor.setComparing(false);
  }

  void _pressUp(PointerEvent event) {
    if (_pressed.remove(event.pointer) == null) return;
    _hold?.cancel();
    editor.setComparing(false);
  }

  void _scroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      editor.zoomAround(editor.scale * math.exp(-event.scrollDelta.dy / 300), event.localPosition);
    } else {
      editor.panBy(-event.scrollDelta);
    }
  }

  /// Fingers on the screen: two pinch the photograph around them and move it with them, and one
  /// drags it while it is magnified. A trackpad's pinch comes as pan-zoom events instead (_pinch).
  double? _fingersStart;

  /// One finger, or the mouse, on a fitted film border that crops the photograph moves the part
  /// of it the aperture shows.
  bool _framing = false;

  void _fingersBegin(ScaleStartDetails details) {
    _fingersStart = editor.scale;
    _framing = details.pointerCount == 1 && !editor.zoomed && !_tooled && editor.printFrame.framable;
    if (_framing) editor.printFrame.beginFraming();
  }

  void _fingers(ScaleUpdateDetails details) {
    final start = _fingersStart;
    if (_framing && details.pointerCount == 1) {
      editor.printFrame
          .dragFraming(details.focalPointDelta, editor.view.photoRect(editor.photoSize).size);
      return;
    }
    if (details.pointerCount > 1 && start != null) {
      editor.zoomAround(start * details.scale, details.localFocalPoint);
    }
    editor.panBy(details.focalPointDelta);
  }

  void _fingersEnd(ScaleEndDetails details) {
    _fingersStart = null;
    if (_framing) editor.printFrame.endFraming();
    _framing = false;
  }

  void _pinch(PointerPanZoomUpdateEvent event) {
    if ((event.scale - 1).abs() > 0.01 && _pinchStart != null) {
      editor.zoomAround(_pinchStart! * event.scale, event.localPosition);
    } else {
      editor.panBy(event.panDelta);
    }
  }

  bool get _tooled => editor.crop.showing || editor.selective.sampling || editor.negatives.sampling;

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final photo = editor.photoSize;
    final rect = editor.view.photoRect(photo);
    final detail = _detail(photo);
    return Listener(
      onPointerDown: _pressDown,
      onPointerMove: _pressMove,
      onPointerUp: _pressUp,
      onPointerCancel: _pressUp,
      onPointerSignal: _scroll,
      onPointerPanZoomStart: (_) => _pinchStart = editor.scale,
      onPointerPanZoomUpdate: _pinch,
      onPointerPanZoomEnd: (_) => _pinchStart = null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
        // The crop and the samplers keep a single finger on a fitted photograph.
        onScaleStart: editor.zoomed || !_tooled ? _fingersBegin : null,
        onScaleUpdate: editor.zoomed || !_tooled ? _fingers : null,
        onScaleEnd: _fingersEnd,
        onDoubleTapDown: (d) =>
            editor.zoomed ? editor.setZoom(null) : editor.zoomAround(1, d.localPosition),
        onDoubleTap: () {},
        child: MouseRegion(
          cursor: !editor.zoomed && !_tooled && editor.printFrame.framable
              ? SystemMouseCursors.grab
              : MouseCursor.defer,
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
    return PresentedLayer(editor.comparing ? '$name.original' : name);
  }
}
