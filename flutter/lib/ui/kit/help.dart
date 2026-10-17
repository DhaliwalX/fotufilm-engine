// The "?" beside a control's name: the catalogue's description of the control in a popover.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'buttons.dart';
import 'icons.dart';
import 'popover.dart';

class HelpButton extends StatelessWidget {
  const HelpButton({super.key, required this.detail, this.size = 14});
  final String? detail;
  final double size;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null || detail.isEmpty) return const SizedBox.shrink();
    return Builder(
      builder: (anchor) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: PressTrigger(
          onPress: () => showAnchored(
            anchor,
            (context, _) => PopoverSurface(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(detail, style: editorText(context, height: 1.45)),
              ),
            ),
            width: 240,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AppIcon('help', size: size, color: Palette.of(context).text.withValues(alpha: .8)),
          ),
        ),
      ),
    );
  }
}
