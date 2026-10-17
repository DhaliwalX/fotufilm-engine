// Floating surfaces: the popover's look, and an overlay anchored to a widget that closes on a
// click outside it. Menus, pickers and help all open through `showAnchored`.
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

/// An open overlay; `close` removes it.
class AnchoredOverlay {
  AnchoredOverlay._(this._entry);
  final OverlayEntry _entry;
  bool _open = true;

  /// Called once it closes, however it closes.
  VoidCallback? onClose;

  /// A modal counts itself out of [openModals] as it closes.
  bool _modal = false;

  bool get isOpen => _open;

  void close() {
    if (!_open) return;
    _open = false;
    _entry.remove();
    if (_modal) {
      _modals.removeWhere((m) => m.$1 == this);
      openModals.value--;
    }
    onClose?.call();
  }
}

/// How many modals are open over the window. While one is, the photograph's commands wait, as
/// the web editor's do while it shows a dialog (useNativeCommands.js `dialog`).
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

/// Opens `builder`'s content under the widget of `anchor`, or over it with `above` (a control at
/// the bottom of the window). A click elsewhere closes it.
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
  // The overlay sits above the app's palette; the opener's goes with it.
  final palette = Palette.of(anchor);
  late final AnchoredOverlay handle;
  final entry = OverlayEntry(
    builder: (context) => PaletteScope(palette: palette, child: Stack(children: [
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => handle.close()),
      ),
      Positioned(
        top: above ? null : origin.dy + box.size.height + gap,
        bottom: above ? overlayBox.size.height - origin.dy + gap : null,
        left: alignEnd ? null : origin.dx,
        right: alignEnd ? overlayBox.size.width - origin.dx - box.size.width : null,
        width: matchWidth ? box.size.width : width,
        child: Builder(builder: (context) => builder(context, () => handle.close())),
      ),
    ])),
  );
  handle = AnchoredOverlay._(entry);
  overlay.insert(entry);
  return handle;
}

/// A modal over the whole window: a dimmed backdrop and `child` centred on it.
AnchoredOverlay showModal(BuildContext context, Widget Function(VoidCallback close) builder,
    {bool dismissible = true}) {
  final palette = Palette.of(context);
  late final AnchoredOverlay handle;
  final entry = OverlayEntry(
    builder: (context) => PaletteScope(palette: palette, child: Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: dismissible ? () => handle.close() : null,
          child: const ColoredBox(color: Color(0x66000000)),
        ),
      ),
      Center(child: builder(() => handle.close())),
    ])),
  );
  handle = AnchoredOverlay._(entry).._modal = true;
  Overlay.of(context).insert(entry);
  _modals.add((handle, dismissible));
  openModals.value++;
  return handle;
}
