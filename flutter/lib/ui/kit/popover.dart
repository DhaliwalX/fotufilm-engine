// Floating surfaces: the popover's look, and an overlay anchored to a widget that closes on a
// click outside it. Menus, pickers and help all open through `showAnchored`. Every overlay comes
// and goes as Spectrum's do: a popover fades in with a short move from its anchor, a dialog fades
// and grows a little over its dimming backdrop, and each fades out quicker than it came. With
// reduced motion they only fade. Each holds the keyboard while open: Tab goes round its controls,
// Esc closes it, and the keys go back where they were.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// Spectrum's popover: the lightest surface, rounded, with a soft drop shadow.
class PopoverSurface extends StatelessWidget {
  const PopoverSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.popover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border.withValues(alpha: .6), width: .5),
        boxShadow: const [BoxShadow(color: Color(0x29000000), blurRadius: 14, offset: Offset(0, 4))],
      ),
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle(style: editorText(context), child: child),
    );
  }
}

/// An open overlay; `close` removes it once it has faded out.
class AnchoredOverlay {
  AnchoredOverlay._();
  late final OverlayEntry _entry;
  bool _open = true;

  /// Set as it closes: it lets clicks through and plays its way out.
  final _leaving = ValueNotifier<bool>(false);

  /// Called once it closes, however it closes.
  VoidCallback? onClose;

  /// Gives the keys back to what had them before it opened.
  VoidCallback? _returnKeys;

  /// A modal counts itself out of [openModals] as it closes.
  bool _modal = false;

  bool get isOpen => _open;

  void close() {
    if (!_open) return;
    _open = false;
    _leaving.value = true;
    if (_modal) {
      _modals.removeWhere((m) => m.$1 == this);
      openModals.value--;
    }
    onClose?.call();
    _returnKeys?.call();
  }
}

/// How many modals are open over the window. While one is, the photograph's commands wait.
final openModals = ValueNotifier<int>(0);

/// The open modals, the newest last, and whether each may be dismissed.
final List<(AnchoredOverlay, bool)> _modals = [];

/// Esc: closes the newest modal where it may be dismissed, as a Spectrum dialog closes; answers
/// whether one was open to take the key.
bool dismissTopModal() {
  if (_modals.isEmpty) return false;
  final (modal, dismissible) = _modals.last;
  if (dismissible) modal.close();
  return true;
}

/// The keys of an open overlay, which the workspace leaves with it (workspace.dart `_keepKeys`).
class OverlayFocusScope extends FocusScopeNode {
  OverlayFocusScope() : super(debugLabel: 'overlay');
}

/// Inserts an overlay whose content `builder` draws with `shown`, 0 to 1 as it comes in and back
/// to 0 as it goes; `close` starts its way out.
AnchoredOverlay showOverlay(BuildContext context,
    Widget Function(BuildContext context, Animation<double> shown, VoidCallback close) builder) {
  final handle = AnchoredOverlay._();
  final palette = Palette.of(context);
  final opener = FocusManager.instance.primaryFocus;
  final scope = OverlayFocusScope();
  handle._entry = OverlayEntry(
    builder: (context) => PaletteScope(
      palette: palette,
      child: FocusScope(
        node: scope,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
            return KeyEventResult.ignored;
          }
          // A modal that may not be dismissed keeps the key.
          if (!handle._modal || !dismissTopModal()) handle.close();
          return KeyEventResult.handled;
        },
        child: _Presence(
          leaving: handle._leaving,
          onGone: () {
            if (handle._entry.mounted) handle._entry.remove();
            scope.dispose();
          },
          builder: (context, shown) => builder(context, shown, handle.close),
        ),
      ),
    ),
  );
  Overlay.of(context).insert(handle._entry);
  // A field that focuses itself keeps it; otherwise the overlay takes the keys.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (handle.isOpen && !scope.hasFocus) scope.requestFocus();
  });
  handle._returnKeys = () {
    if (opener != null && opener.context != null && opener.canRequestFocus) opener.requestFocus();
  };
  return handle;
}

/// An overlay's way in and out.
class _Presence extends StatefulWidget {
  const _Presence({required this.leaving, required this.onGone, required this.builder});
  final ValueNotifier<bool> leaving;
  final VoidCallback onGone;
  final Widget Function(BuildContext context, Animation<double> shown) builder;

  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    reverseDuration: const Duration(milliseconds: 100),
  );
  late final Animation<double> _shown = CurvedAnimation(
      parent: _controller, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  @override
  void initState() {
    super.initState();
    widget.leaving.addListener(_leave);
    _controller.forward();
  }

  void _leave() {
    if (!widget.leaving.value) return;
    setState(() {});
    _controller.reverse().whenComplete(widget.onGone);
  }

  @override
  void dispose() {
    widget.leaving.removeListener(_leave);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: widget.leaving.value,
        child: widget.builder(context, _shown),
      );
}

/// A popover's way in: it fades and moves 4 points towards its place.
class PopoverTransition extends StatelessWidget {
  const PopoverTransition({super.key, required this.shown, required this.child});
  final Animation<double> shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return FadeTransition(
      opacity: shown,
      child: still
          ? child
          : AnimatedBuilder(
              animation: shown,
              builder: (context, child) =>
                  Transform.translate(offset: Offset(0, -4 * (1 - shown.value)), child: child),
              child: child,
            ),
    );
  }
}

/// A notice or a tip coming into view: it fades in with a short move of `rise` points, once,
/// when first shown.
class Appear extends StatelessWidget {
  const Appear(
      {super.key, required this.child, this.rise = 6, this.duration = const Duration(milliseconds: 160)});
  final Widget child;
  final double rise;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: still ? child : Transform.translate(offset: Offset(0, rise * (1 - t)), child: child),
      ),
    );
  }
}

/// Opens `builder`'s content under the widget of `anchor`, or over it with `above` (a control at
/// the bottom of the window). Where that side has too little room it opens on the other, as
/// Spectrum's popovers flip, and it is never taller than the window allows. A click elsewhere
/// closes it.
AnchoredOverlay showAnchored(
  BuildContext anchor,
  Widget Function(BuildContext context, VoidCallback close) builder, {
  bool alignEnd = false,
  double gap = 4,
  double? width,
  bool matchWidth = false,
  bool above = false,
}) {
  final overlay = Overlay.of(anchor);
  final overlayBox = overlay.context.findRenderObject() as RenderBox;
  final box = anchor.findRenderObject() as RenderBox;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
  // The overlay sits above the app's palette; the opener's goes with it (showOverlay).
  return showOverlay(
    anchor,
    (context, shown, close) => Stack(children: [
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: close),
      ),
      Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: _AnchoredLayout(
            anchor: origin & box.size,
            gap: gap,
            width: matchWidth ? box.size.width : width,
            alignEnd: alignEnd,
            above: above,
          ),
          child: PopoverTransition(
            shown: shown,
            child: Builder(builder: (context) => builder(context, close)),
          ),
        ),
      ),
    ]),
  );
}

/// Places a popover by its anchor: on the side asked for when it fits there, else on the side
/// with more room, kept inside the window with a margin.
class _AnchoredLayout extends SingleChildLayoutDelegate {
  _AnchoredLayout({
    required this.anchor,
    required this.gap,
    required this.width,
    required this.alignEnd,
    required this.above,
  });

  final Rect anchor;
  final double gap;
  final double? width;
  final bool alignEnd, above;

  static const _margin = 8.0;

  double _below(Size size) => size.height - anchor.bottom - gap - _margin;
  double _over() => anchor.top - gap - _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final room = _below(size) > _over() ? _below(size) : _over();
    final across = size.width - 2 * _margin;
    final w = width?.clamp(0.0, across);
    return BoxConstraints(
      minWidth: w ?? 0,
      maxWidth: w ?? across,
      maxHeight: room.clamp(0.0, size.height),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final below = _below(size), over = _over();
    final fitsPreferred = above ? child.height <= over : child.height <= below;
    final up = fitsPreferred ? above : over > below;
    final x = (alignEnd ? anchor.right - child.width : anchor.left)
        .clamp(_margin, (size.width - child.width - _margin).clamp(_margin, double.infinity));
    final y = up ? anchor.top - gap - child.height : anchor.bottom + gap;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AnchoredLayout old) =>
      anchor != old.anchor ||
      gap != old.gap ||
      width != old.width ||
      alignEnd != old.alignEnd ||
      above != old.above;
}

/// A modal over the whole window: a dimmed backdrop and `child` centred on it.
AnchoredOverlay showModal(BuildContext context, Widget Function(VoidCallback close) builder,
    {bool dismissible = true}) {
  final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final handle = showOverlay(
    context,
    (context, shown, close) => Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: dismissible ? close : null,
          child: FadeTransition(opacity: shown, child: const ColoredBox(color: Color(0x66000000))),
        ),
      ),
      Center(
        child: FadeTransition(
          opacity: shown,
          child: still
              ? builder(close)
              : ScaleTransition(
                  scale: Tween(begin: .96, end: 1.0).animate(shown), child: builder(close)),
        ),
      ),
    ]),
  ).._modal = true;
  _modals.add((handle, dismissible));
  openModals.value++;
  return handle;
}
