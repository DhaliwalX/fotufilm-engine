// The workspace's dialogs (styles/dialogs.css): the card they share. Export and the keyboard
// shortcuts have their own files (export_dialog.dart, shortcuts_dialog.dart).
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// A dialog's card: its title, its body and its buttons on the right.
class DialogCard extends StatelessWidget {
  const DialogCard({
    super.key,
    required this.title,
    required this.children,
    required this.actions,
    this.width = 440,
  });

  final String title;
  final List<Widget> children, actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: palette.dark ? const Color(0xFF222222) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 40, offset: Offset(0, 10))],
      ),
      child: DefaultTextStyle(
        style: editorText(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: editorText(context, size: TextSizes.dialog, weight: FontWeight.w700)),
            const SizedBox(height: 14),
            ...children,
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                actions[i],
              ],
            ]),
          ],
        ),
      ),
    );
  }
}
