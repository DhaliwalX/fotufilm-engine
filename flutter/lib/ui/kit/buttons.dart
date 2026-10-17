// Spectrum's buttons at size S: the quiet ActionButton and ToggleButton the toolbars use, and the
// filled pill Button of dialogs and inspector actions.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'icons.dart';
import 'tooltip.dart';

/// Tracks hover and press for a control that tints itself.
mixin PointerTint<T extends StatefulWidget> on State<T> {
  bool hovered = false, pressed = false;

  Widget tinted({required Widget child, VoidCallback? onTap}) => MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = pressed = false),
        child: GestureDetector(
          onTapDown: onTap == null ? null : (_) => setState(() => pressed = true),
          onTapUp: (_) => setState(() => pressed = false),
          onTapCancel: () => setState(() => pressed = false),
          onTap: onTap,
          child: child,
        ),
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
  });

  final String? icon, label, tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size, iconSize;

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
        child: Container(
          height: widget.size,
          constraints: BoxConstraints(minWidth: widget.size),
          padding: widget.label == null ? null : const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Metrics.radius)),
          alignment: Alignment.center,
          child: widget.label != null
              ? Text(widget.label!, style: editorText(context, color: fg))
              : AppIcon(widget.icon!, size: widget.iconSize, color: fg),
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
          // As wide as its label unless it expands, wherever it is placed.
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
