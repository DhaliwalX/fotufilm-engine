// The library's menus and dialogs: a photo's context menu at the pointer (PhotoMenu.jsx), Rename
// (RenameDialog.jsx), and the confirmations to move photos to the Trash and to remove a folder.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../model/library_model.dart';
import '../../kit/kit.dart';
import '../../theme/theme.dart';
import '../dialogs.dart';

/// Opens a menu with its corner at `position` (window coordinates), kept inside the window.
void showMenuAt(BuildContext context, Offset position, List<MenuItem> items, {double width = 220}) {
  final overlay = Overlay.of(context);
  final box = overlay.context.findRenderObject() as RenderBox;
  final at = box.globalToLocal(position);
  OverlayEntry? entry;
  void close() {
    entry?.remove();
    entry = null;
  }

  entry = OverlayEntry(
    builder: (context) => Stack(children: [
      Positioned.fill(
        child: Listener(behavior: HitTestBehavior.opaque, onPointerDown: (_) => close()),
      ),
      CustomSingleChildLayout(
        delegate: _MenuPlacement(at, width),
        child: MenuList(items: items, onClose: close),
      ),
    ]),
  );
  overlay.insert(entry!);
}

class _MenuPlacement extends SingleChildLayoutDelegate {
  _MenuPlacement(this.at, this.width);
  final Offset at;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: width).loosen().copyWith(minWidth: width);

  @override
  Offset getPositionForChild(Size size, Size child) => Offset(
        (at.dx + child.width > size.width - 8 ? at.dx - child.width : at.dx).clamp(8, size.width),
        (at.dy + child.height > size.height - 8 ? at.dy - child.height : at.dy).clamp(8, size.height),
      );

  @override
  bool shouldRelayout(_MenuPlacement old) => old.at != at || old.width != width;
}

/// Renames one photo: the name field opens with the name before the extension selected.
void showRenameDialog(BuildContext context, LibraryPhoto photo, ValueChanged<String> onRename) =>
    showModal(context, (close) => _RenameDialog(photo: photo, onRename: onRename, onClose: close));

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.photo, required this.onRename, required this.onClose});
  final LibraryPhoto photo;
  final ValueChanged<String> onRename;
  final VoidCallback onClose;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.photo.name);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final dot = widget.photo.name.lastIndexOf('.');
    _name.selection =
        TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : widget.photo.name.length);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _trimmed => _name.text.trim();

  void _submit() {
    if (nameProblem(_trimmed) != null) return;
    if (_trimmed != widget.photo.name) widget.onRename(_trimmed);
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final problem = nameProblem(_trimmed);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
      child: DialogCard(
        title: 'Rename Photo',
        width: 360,
        actions: [
          PillButton('Cancel', onPressed: widget.onClose),
          PillButton('Rename',
              variant: ButtonVariant.accent, onPressed: problem == null ? _submit : null),
        ],
        children: [
          Text('Name', style: editorText(context, size: TextSizes.label, color: palette.muted)),
          const SizedBox(height: 4),
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: palette.fieldFill,
              borderRadius: BorderRadius.circular(Metrics.radius),
              border: Border.all(
                  color: problem != null ? const Color(0xFFD73220) : const Color(0x00000000)),
            ),
            child: EditableField(
              controller: _name,
              focusNode: _focus,
              style: editorText(context),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (problem != null) ...[
            const SizedBox(height: 4),
            Text(problem,
                style: editorText(context, size: TextSizes.label, color: const Color(0xFFD73220))),
          ],
        ],
      ),
    );
  }
}

/// A destructive question: its title, an optional explanation, Cancel and the action in red.
void showConfirmDialog(BuildContext context,
        {required String title, String? body, required String action, required VoidCallback onConfirm}) =>
    showModal(
      context,
      (close) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
        child: Focus(
          autofocus: true,
          child: DialogCard(
            title: title,
            width: 400,
            actions: [
              PillButton('Cancel', onPressed: close),
              PillButton(action, variant: ButtonVariant.negative, onPressed: () {
                close();
                onConfirm();
              }),
            ],
            children: [if (body != null) Text(body)],
          ),
        ),
      ),
    );
