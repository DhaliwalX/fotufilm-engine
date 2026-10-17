// Spectrum's ProgressBar at size S: a thin rounded track, filled to `value`, or a sliding segment
// while the amount is unknown (null).
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

class ProgressBar extends StatefulWidget {
  const ProgressBar({super.key, this.value});

  /// 0 to 1; null while indeterminate.
  final double? value;

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> with SingleTickerProviderStateMixin {
  late final _slide =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ProgressBar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.value == null && !_slide.isAnimating) _slide.repeat();
    if (widget.value != null && _slide.isAnimating) _slide.stop();
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return SizedBox(
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final fill = ColoredBox(color: palette.gray800);
          return ColoredBox(
            color: palette.gray300,
            child: widget.value != null
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.ease,
                      width: width * widget.value!.clamp(0, 1),
                      child: fill,
                    ),
                  )
                : AnimatedBuilder(
                    animation: _slide,
                    builder: (context, child) => Stack(children: [
                      Positioned(
                        left: (_slide.value * 1.7 - .7) * width,
                        width: width * .7,
                        top: 0,
                        bottom: 0,
                        child: child!,
                      ),
                    ]),
                    child: fill,
                  ),
          );
        }),
      ),
    );
  }
}
