// The "?" beside a control's name: the catalogue's description of the control in a popover.
import 'package:flutter/widgets.dart';

import '../../app/strings.dart';
import '../theme/theme.dart';
import 'buttons.dart';
import 'focus.dart';
import 'icons.dart';
import 'popover.dart';

class HelpButton extends StatelessWidget {
  const HelpButton({super.key, required this.detail, this.size = 14});
  final String? detail;
  final double size;

  @override
  Widget build(BuildContext context) {
    final source = detail;
    if (source == null || source.isEmpty) return const SizedBox.shrink();
    final shown = AppStrings.tr(source);
    return Builder(builder: (anchor) {
      void open() => showAnchored(
            anchor,
            (context, _) => PopoverSurface(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(shown, style: editorText(context, height: 1.45)),
              ),
            ),
            width: 240,
          );
      return KeyTarget(
        onActivate: open,
        label: AppStrings.tr('Help'),
        radius: size,
        child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: PressTrigger(
          onPress: open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AppIcon('help', size: size, color: Palette.of(context).text.withValues(alpha: .8)),
          ),
        ),
      ),
      );
    });
  }
}
