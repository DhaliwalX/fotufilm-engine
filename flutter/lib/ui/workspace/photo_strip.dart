// The open photographs (web/src/editor/PhotoStrip.jsx), compact: the shown one's path, then a
// row of frames, the shown one ringed in the accent, each closed by the button on its corner.
// Shift-click and ⌘-click choose more photos for Paste Settings and presets (strip_selection.dart);
// those chosen with the shown one are ringed in a fainter accent.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'picture.dart';

class PhotoStrip extends StatelessWidget {
  const PhotoStrip({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      color: palette.panel,
      padding: Metrics.stripPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(editor.active?.path ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: editorText(context, size: TextSizes.caption, color: palette.muted, height: 1.3)),
        const SizedBox(height: 2),
        SizedBox(
          height: Metrics.stripItem.height + 6,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: editor.documents.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) => _StripItem(
              doc: editor.documents[index],
              selected: index == editor.activeIndex,
              chosen: editor.strip.isChosen(editor.documents[index]),
              onTap: () {
                final keys = HardwareKeyboard.instance;
                editor.strip.press(editor.documents[index],
                    range: keys.isShiftPressed,
                    toggle: keys.isMetaPressed || keys.isControlPressed);
              },
              onClose: () => editor.closeDocument(index),
            ),
          ),
        ),
      ]),
    );
  }
}

class _StripItem extends StatefulWidget {
  const _StripItem({
    required this.doc,
    required this.selected,
    required this.chosen,
    required this.onTap,
    required this.onClose,
  });
  final PhotoDocument doc;
  final bool selected, chosen;
  final VoidCallback onTap, onClose;

  @override
  State<_StripItem> createState() => _StripItemState();
}

class _StripItemState extends State<_StripItem> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final image = widget.doc.importPicture;
    return tinted(
      child: Padding(
        padding: const EdgeInsets.only(top: 6, right: 6),
        child: Stack(clipBehavior: Clip.none, children: [
          GestureDetector(
            onTap: widget.onTap,
            child: Container(
              width: Metrics.stripItem.width,
              height: Metrics.stripItem.height,
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                border: Border.all(
                    color: widget.selected
                        ? palette.accent
                        : widget.chosen
                            ? palette.accent.withValues(alpha: .45)
                            : const Color(0x00000000),
                    width: 2),
                borderRadius: BorderRadius.circular(3),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: image == null
                    ? Container(
                        color: palette.canvas,
                        alignment: Alignment.center,
                        child: Text(widget.doc.name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            style: editorText(context,
                                size: TextSizes.caption, color: palette.muted)))
                    : EnginePicture(image, fit: BoxFit.contain),
              ),
            ),
          ),
          if (hovered)
            Positioned(
              top: -6,
              right: -6,
              child: GestureDetector(
                onTap: widget.onClose,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: palette.panel,
                    shape: BoxShape.circle,
                    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 3)],
                  ),
                  child: const Center(child: AppIcon('close', size: 12)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
