// Keyboard shortcuts: the dialog's fixed rows, each action with its keys on the right, muted.
import 'package:flutter/widgets.dart';

import '../../app/editor_shortcuts.dart';
import '../../model/editor.dart';
import '../theme/theme.dart';
import 'app_dialogs.dart';

class ShortcutsDialog extends StatelessWidget {
  const ShortcutsDialog({super.key, required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final muted = editorText(context, color: Palette.of(context).muted);
    return AppDialogCard(
      title: 'Keyboard shortcuts',
      onDismiss: onClose,
      children: [
        for (final (action, keys) in shortcutRows(editor))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(action)),
              const SizedBox(width: 12),
              Text(keys, style: muted),
            ]),
          ),
      ],
    );
  }
}
