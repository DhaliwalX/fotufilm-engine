// Spectrum's buttons at size S: the quiet ActionButton and ToggleButton the toolbars use, and the
// filled pill Button of dialogs and inspector actions.
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'focus.dart';
import 'icons.dart';
import 'tooltip.dart';

/// Tracks hover and press for a control that tints itself. A control that opens a menu or a
/// popover acts as the press starts (`opensMenu`), the rest as it ends.
mixin PointerTint<T extends StatefulWidget> on State<T> {
  bool hovered = false, pressed = false;

  /// The control under the pointer and the keyboard (KeyTarget): `label` and the states are
  /// what VoiceOver reads.
  Widget tinted({
    required Widget child,
    VoidCallback? onTap,
    bool opensMenu = false,
    String? label,
    String? value,
    bool? selected,
    bool? expanded,
    double radius = Metrics.radius,
  }) =>
      KeyTarget(
        onActivate: onTap,
        label: label,
        value: value,
        selected: selected,
        expanded: expanded,
        radius: radius,
        child: MouseRegion(
          onEnter: (_) => setState(() => hovered = true),
          onExit: (_) => setState(() => hovered = pressed = false),
          child: opensMenu
              ? PressTrigger(onPress: onTap, child: child)
              : GestureDetector(
                  onTapDown: onTap == null ? null : (_) => setState(() => pressed = true),
                  onTapUp: (_) => setState(() => pressed = false),
                  onTapCancel: () => setState(() => pressed = false),
                  onTap: onTap,
                  child: child,
                ),
        ),
      );
}

/// Runs `onPress` as the primary button goes down, as Spectrum's menu triggers and pickers open
/// (react-aria `usePress` onPressStart). It reads the pointer outside the gesture arena, so a
/// scroll view or a double-click around the control adds no wait.
class PressTrigger extends StatelessWidget {
  const PressTrigger({super.key, required this.onPress, required this.child});
  final VoidCallback? onPress;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: onPress == null
            ? null
            : (event) {
                if (event.buttons == kPrimaryButton) onPress!();
              },
        child: child,
      );
}

/// A quiet button: transparent at rest, a soft tint on hover and press, and the neutral fill
/// when it is a selected toggle. An icon, or a text `label`.
class QuietButton extends StatefulWidget {
  const QuietButton({
    super.key,
    this.icon,
    this.label,
    this.tooltip,
    this.onPressed,
    this.selected = false,
    this.size = Metrics.control,
    this.iconSize = Metrics.icon,
    this.upsideDown = false,
    this.opensMenu = false,
  });

  final String? icon, label, tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  /// It opens a menu or popover, so it acts as the press starts.
  final bool opensMenu;
  final double size, iconSize;

  /// The icon turned half round (a chevron pointing up).
  final bool upsideDown;

  @override
  State<QuietButton> createState() => _QuietButtonState();
}

class _QuietButtonState extends State<QuietButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = widget.onPressed != null;
    final fg = !enabled
        ? palette.text.withValues(alpha: .3)
        : widget.selected
            ? palette.onSelected
            : palette.text;
    final bg = widget.selected
        ? palette.gray800
        : pressed
            ? palette.pressed
            : hovered && enabled
                ? palette.hover
                : null;
    return HoverTip(
      message: widget.tooltip,
      child: tinted(
        onTap: widget.onPressed,
        opensMenu: widget.opensMenu,
        label: widget.label ?? widget.tooltip,
        selected: widget.selected ? true : null,
        child: Container(
          height: widget.size,
          constraints: BoxConstraints(minWidth: widget.size),
          padding: widget.label == null ? null : const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Metrics.radius)),
          // Centred in its own width, so a text button under a stretching column stays its size.
          child: Center(
            widthFactor: 1,
            child: widget.label != null
              ? Text(widget.label!, style: editorText(context, color: fg))
              : RotatedBox(
                  quarterTurns: widget.upsideDown ? 2 : 0,
                  child: AppIcon(widget.icon!, size: widget.iconSize, color: fg)),
          ),
        ),
      ),
    );
  }
}

enum ButtonVariant { secondary, accent, negative }

/// A filled pill: secondary grey, the accent blue, or the negative red.
class PillButton extends StatefulWidget {
  const PillButton(this.label,
      {super.key, this.onPressed, this.variant = ButtonVariant.secondary, this.expand = false});
  final String label;
  final VoidCallback? onPressed;
  final ButtonVariant variant;
  final bool expand;

  @override
  State<PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<PillButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = widget.onPressed != null;
    final (Color bg, Color fg) = switch (widget.variant) {
      ButtonVariant.accent => (
          palette.dark ? const Color(0xFF5681FF) : const Color(0xFF3B63FB),
          const Color(0xFFFFFFFF)
        ),
      ButtonVariant.negative => (
          palette.dark ? const Color(0xFFFC432E) : const Color(0xFFD73220),
          const Color(0xFFFFFFFF)
        ),
      ButtonVariant.secondary => (palette.gray100, palette.text),
    };
    return tinted(
      onTap: widget.onPressed,
      label: widget.label,
      radius: Metrics.control / 2,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: Container(
          height: Metrics.control,
          width: widget.expand ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: hovered && enabled ? Color.lerp(bg, palette.text, .06) : bg,
            borderRadius: BorderRadius.circular(Metrics.control / 2),
          ),
          // Its own width unless it expands, even under a stretching column.
          child: Center(
            widthFactor: widget.expand ? null : 1,
            child: Text(widget.label,
                style: editorText(context, weight: FontWeight.w700, color: fg)),
          ),
        ),
      ),
    );
  }
}
