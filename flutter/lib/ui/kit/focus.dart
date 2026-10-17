// The keyboard and VoiceOver on the kit's controls, as react-aria gives Spectrum's: Tab reaches a
// control, Return or Space works it, the arrow keys move a slider, and a ring shows where the
// keyboard is (a click puts none there). Each names itself to the screen reader with its role and
// state.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

class KeyTarget extends StatefulWidget {
  const KeyTarget({
    super.key,
    required this.child,
    this.onActivate,
    this.label,
    this.value,
    this.button = true,
    this.toggled,
    this.selected,
    this.expanded,
    this.onIncrease,
    this.onDecrease,
    this.increasedValue,
    this.decreasedValue,
    this.onNudge,
    this.radius = Metrics.radius,
    this.ringInset = 0,
  });

  final Widget child;

  /// Return and Space; null leaves it out of Tab's way, as a disabled control is.
  final VoidCallback? onActivate;

  /// What VoiceOver reads: its name, and its value where it has one.
  final String? label, value;
  final bool button;

  /// A switch or checkbox's state; a segment or tab's; a disclosure's.
  final bool? toggled, selected, expanded;

  /// A slider: the arrow keys step it (Shift by ten), and VoiceOver's adjust gestures do.
  final void Function(int steps)? onIncrease, onDecrease;
  final String? increasedValue, decreasedValue;

  /// A handle moved in two dimensions (a crop corner, the grade pad, a panel's edge): an arrow
  /// key's direction, right and down positive, and whether Shift is held.
  final void Function(Offset direction, bool shift)? onNudge;

  final double radius;

  /// How far inside the control's edge the ring sits (negative: outside).
  final double ringInset;

  @override
  State<KeyTarget> createState() => _KeyTargetState();
}

class _StepIntent extends Intent {
  const _StepIntent(this.steps);
  final int steps;
}

class _NudgeIntent extends Intent {
  const _NudgeIntent(this.direction, this.shift);
  final Offset direction;
  final bool shift;
}

class _KeyTargetState extends State<KeyTarget> {
  bool _ring = false;

  bool get _slider => widget.onIncrease != null || widget.onDecrease != null;
  bool get _nudges => widget.onNudge != null;

  void _step(int steps) {
    if (steps > 0) widget.onIncrease?.call(steps);
    if (steps < 0) widget.onDecrease?.call(-steps);
  }

  static const _activate = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  static const _steps = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
    SingleActivator(LogicalKeyboardKey.arrowUp): _StepIntent(1),
    SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowDown): _StepIntent(-1),
    SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): _StepIntent(10),
    SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): _StepIntent(10),
    SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): _StepIntent(-10),
    SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): _StepIntent(-10),
    SingleActivator(LogicalKeyboardKey.pageUp): _StepIntent(10),
    SingleActivator(LogicalKeyboardKey.pageDown): _StepIntent(-10),
  };

  static final _nudgeKeys = <ShortcutActivator, Intent>{
    for (final shift in [false, true]) ...{
      SingleActivator(LogicalKeyboardKey.arrowRight, shift: shift): _NudgeIntent(const Offset(1, 0), shift),
      SingleActivator(LogicalKeyboardKey.arrowLeft, shift: shift): _NudgeIntent(const Offset(-1, 0), shift),
      SingleActivator(LogicalKeyboardKey.arrowDown, shift: shift): _NudgeIntent(const Offset(0, 1), shift),
      SingleActivator(LogicalKeyboardKey.arrowUp, shift: shift): _NudgeIntent(const Offset(0, -1), shift),
    },
  };

  @override
  Widget build(BuildContext context) {
    final activate = widget.onActivate;
    final enabled = activate != null || _slider || _nudges;
    final palette = Palette.of(context);
    return Semantics(
      container: true,
      button: widget.button && !_slider && widget.toggled == null,
      slider: _slider,
      toggled: widget.toggled,
      selected: widget.selected,
      expanded: widget.expanded,
      enabled: enabled,
      label: widget.label,
      value: widget.value,
      increasedValue: widget.increasedValue,
      decreasedValue: widget.decreasedValue,
      onTap: activate,
      onIncrease: widget.onIncrease == null ? null : () => _step(1),
      onDecrease: widget.onDecrease == null ? null : () => _step(-1),
      child: FocusableActionDetector(
        enabled: enabled,
        shortcuts: {
          if (activate != null) ..._activate,
          if (_slider) ..._steps,
          if (_nudges) ..._nudgeKeys,
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => activate?.call()),
          _StepIntent: CallbackAction<_StepIntent>(onInvoke: (intent) => _step(intent.steps)),
          _NudgeIntent: CallbackAction<_NudgeIntent>(
              onInvoke: (intent) => widget.onNudge?.call(intent.direction, intent.shift)),
        },
        onShowFocusHighlight: (show) => setState(() => _ring = show),
        child: Stack(clipBehavior: Clip.none, fit: StackFit.passthrough, children: [
          // Named here, its own text would be read twice.
          ExcludeSemantics(excluding: widget.label != null, child: widget.child),
          if (_ring)
            Positioned.fill(
              left: widget.ringInset,
              top: widget.ringInset,
              right: widget.ringInset,
              bottom: widget.ringInset,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: palette.accent, width: 2, strokeAlign: BorderSide.strokeAlignOutside),
                    borderRadius: BorderRadius.circular(widget.radius),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
