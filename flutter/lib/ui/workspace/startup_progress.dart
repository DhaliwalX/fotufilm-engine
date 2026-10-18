// The card over the empty viewer while the engine starts (web/src/editor/StartupProgress.jsx,
// startup-progress.css): the brand over a small progress bar and what is loading. It fades in,
// and fades away once the bar has reached its end.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../model/startup.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'toolbar.dart' show FotufilmBrand;

class StartupProgress extends StatefulWidget {
  const StartupProgress({super.key, required this.progress, this.compact = false});
  final ValueListenable<StartupState> progress;

  /// The compact layout sits it lower over its smaller viewer.
  final bool compact;

  @override
  State<StartupProgress> createState() => _StartupProgressState();
}

class _StartupProgressState extends State<StartupProgress> {
  bool _visible = true;
  bool _shown = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_changed);
    // Fades in from the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
    _changed();
  }

  @override
  void dispose() {
    widget.progress.removeListener(_changed);
    _hide?.cancel();
    super.dispose();
  }

  void _changed() {
    final done = widget.progress.value.done;
    _hide?.cancel();
    if (!done) {
      if (!_visible) setState(() => _visible = true);
      return;
    }
    // Let the bar reach its final value before fading the loader away.
    _hide = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _visible = false);
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final state = widget.progress.value;
    return Positioned(
      left: 0,
      right: 0,
      bottom: widget.compact ? 60 : 84,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: _visible && _shown ? 1 : 0,
            duration: const Duration(milliseconds: 350),
            child: LayoutBuilder(
              builder: (context, constraints) => Container(
                width: (constraints.maxWidth - 48).clamp(0, 280).toDouble(),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: palette.panel,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Color(0x0C000000), blurRadius: 24, offset: Offset(0, 4)),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(alignment: Alignment.centerLeft, child: FotufilmBrand()),
                    const SizedBox(height: 14),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 120),
                      child: Align(
                        key: ValueKey(state.label),
                        alignment: Alignment.centerLeft,
                        child: Text(state.label,
                            style: editorText(context, size: TextSizes.label,
                                color: palette.text.withValues(alpha: .75))),
                      ),
                    ),
                    const SizedBox(height: 6),
                    ProgressBar(value: state.done ? 1 : null),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
