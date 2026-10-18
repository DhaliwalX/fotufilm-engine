// The opened photo's picture flies from its library tile to where the viewer will fit it, and stays
// there until the developed photograph is on screen.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../model/editor.dart';
import '../picture.dart';

/// The viewer's canvas area, where the handoff lands.
final libraryViewerKey = GlobalKey(debugLabel: 'viewer canvas');

class LibraryHandoffLayer extends StatefulWidget {
  const LibraryHandoffLayer({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<LibraryHandoffLayer> createState() => _LibraryHandoffLayerState();
}

class _LibraryHandoffLayerState extends State<LibraryHandoffLayer> with TickerProviderStateMixin {
  static const _ease = Cubic(.2, .8, .2, 1);
  late final _flight =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 240));
  LibraryHandoff? _handoff;
  Rect? _target;
  Timer? _timeout;

  EditorModel get editor => widget.editor;

  @override
  void initState() {
    super.initState();
    editor.library.addListener(_changed);
    editor.addListener(_changed);
    _flight.addStatusListener((_) => _changed());
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) editor.library.endHandoff();
    });
  }

  @override
  void dispose() {
    editor.library.removeListener(_changed);
    editor.removeListener(_changed);
    _timeout?.cancel();
    _flight.dispose();
    _fade.dispose();
    super.dispose();
  }

  /// Where the viewer fits a picture of `aspect`: the canvas less its inset.
  Rect? _viewerRect(double aspect) {
    final box = libraryViewerKey.currentContext?.findRenderObject() as RenderBox?;
    final layer = context.findRenderObject() as RenderBox?;
    if (box == null || layer == null || !box.attached) return null;
    final room = box.localToGlobal(Offset.zero, ancestor: layer) & box.size;
    const inset = ViewState.fitInset;
    final fit = math.min((room.width - inset * 2) / aspect, room.height - inset * 2);
    return Rect.fromCenter(center: room.center, width: fit * aspect, height: fit);
  }

  void _changed() {
    if (!mounted) return;
    final handoff = editor.library.handoff;
    if (handoff != _handoff) {
      _handoff = handoff;
      _timeout?.cancel();
      _fade.value = 0;
      _target = null;
      if (handoff != null) {
        _target = _viewerRect(handoff.image.width / handoff.image.height);
        _flight.forward(from: 0);
        _timeout = Timer(const Duration(seconds: 15), editor.library.endHandoff);
      }
      setState(() {});
      return;
    }
    if (handoff == null || _fade.isAnimating || _fade.isCompleted) return;
    // Once landed, it gives way to the developed photograph, or to an error.
    final doc = editor.active;
    final shown = doc != null &&
        doc.path == handoff.path &&
        (doc.preview != null || doc.previewImage != null);
    if (_flight.isCompleted && (shown || editor.error != null)) _fade.forward();
  }

  @override
  Widget build(BuildContext context) {
    final handoff = _handoff, target = _target;
    if (handoff == null || target == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([_flight, _fade]),
        builder: (context, child) {
          final layer = context.findRenderObject() as RenderBox?;
          final origin = layer == null || !layer.attached
              ? handoff.rect
              : handoff.rect.shift(-layer.localToGlobal(Offset.zero));
          final rect = Rect.lerp(origin, target, _ease.transform(_flight.value))!;
          return Stack(children: [
            Positioned.fromRect(
              rect: rect,
              child: Opacity(opacity: 1 - Curves.easeOut.transform(_fade.value), child: child),
            ),
          ]);
        },
        child: EnginePicture(handoff.image),
      ),
    );
  }
}
