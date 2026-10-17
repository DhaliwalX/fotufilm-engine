// The panels' thin overlay scrollbar (`scrollbar-width: thin`). The wheel, the trackpad's two
// fingers and touch scroll; a mouse drag does not, so dragging a slider never moves the panel.
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

class ThinScroll extends StatelessWidget {
  const ThinScroll({super.key, required this.controller, required this.child});
  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => RawScrollbar(
        controller: controller,
        thickness: 5,
        radius: const Radius.circular(3),
        thumbColor: Palette.of(context).text.withValues(alpha: .28),
        mainAxisMargin: 4,
        crossAxisMargin: 2,
        child: ScrollConfiguration(behavior: const _Plain(), child: child),
      );
}

class _Plain extends ScrollBehavior {
  const _Plain();
  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;
  @override
  Set<PointerDeviceKind> get dragDevices =>
      const {PointerDeviceKind.touch, PointerDeviceKind.trackpad};
}
