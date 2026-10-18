// Spectrum's tooltip: a small dark label under a control after a short hover.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'popover.dart' show Appear;

class HoverTip extends StatefulWidget {
  const HoverTip({super.key, required this.message, required this.child});
  final String? message;
  final Widget child;

  @override
  State<HoverTip> createState() => _HoverTipState();
}

class _HoverTipState extends State<HoverTip> {
  static const _delay = Duration(milliseconds: 600);
  final _link = LayerLink();
  OverlayEntry? _entry;
  bool _hovering = false;

  void _show() {
    if (_entry != null || widget.message == null || !mounted) return;
    final palette = Palette.of(context);
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomCenter,
          followerAnchor: Alignment.topCenter,
          offset: const Offset(0, 6),
          child: IgnorePointer(
            child: Appear(
              rise: -2,
              duration: const Duration(milliseconds: 120),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 240),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.tooltip,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(widget.message!,
                    style: editorText(context, size: TextSizes.body, color: palette.onSelected)),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) {
            _hovering = true;
            Future.delayed(_delay, () {
              if (_hovering) _show();
            });
          },
          onExit: (_) {
            _hovering = false;
            _hide();
          },
          child: Listener(onPointerDown: (_) => _hide(), child: widget.child),
        ),
      );
}
