// Spectrum's Checkbox at size S: a small rounded box, filled with a tick when chosen, and its
// label; the whole row takes the click.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'icons.dart';

class CheckboxRow extends StatelessWidget {
  const CheckboxRow({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: value ? palette.gray800 : null,
              border: value ? null : Border.all(color: palette.text.withValues(alpha: .55), width: 1.5),
              borderRadius: BorderRadius.circular(3),
            ),
            child: value ? AppIcon('check', size: 12, color: palette.onSelected) : null,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(label, style: editorText(context))),
        ]),
      ),
    );
  }
}
