// The open photographs (web/src/editor/PhotoStrip.jsx), compact: the shown one's path, then a
// row of frames, the shown one ringed in the accent, each closed by the button on its corner.
// Photos that came with one (its folder, its roll) wait in the strip undecoded, showing the
// engine's picture of the file, drawn once their frame is on screen; one is imported when chosen.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/library_model.dart' show stripPath;
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'picture.dart';

class PhotoStrip extends StatelessWidget {
  const PhotoStrip({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.strip,
        builder: (context, _) {
          final items = editor.strip.items;
          if (items.length < 2) return const SizedBox.shrink();
          return _strip(context, items);
        },
      );

  Widget _strip(BuildContext context, List<StripItem> items) {
    final palette = Palette.of(context);
    final active = editor.active;
    return Container(
      color: palette.panel,
      padding: Metrics.stripPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _StartClipped(active == null ? '' : stripPath(active.path),
            style: editorText(context, size: TextSizes.caption, color: palette.muted, height: 1.3)),
        const SizedBox(height: 2),
        SizedBox(
          height: Metrics.stripItem.height + 6,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // Frames are built as they come into view, which is when waiting ones are drawn.
            cacheExtent: 0,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final item = items[index];
              return _StripItem(
                key: ValueKey(item.path),
                editor: editor,
                item: item,
                selected: item.doc != null && item.doc == active,
                onTap: () => editor.strip.choose(item),
                onClose: () => editor.strip.close(item),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _StripItem extends StatefulWidget {
  const _StripItem({
    super.key,
    required this.editor,
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });
  final EditorModel editor;
  final StripItem item;
  final bool selected;
  final VoidCallback onTap, onClose;

  @override
  State<_StripItem> createState() => _StripItemState();
}

class _StripItemState extends State<_StripItem> with PointerTint {
  ui.Image? _thumbnail;

  @override
  void initState() {
    super.initState();
    _draw();
  }

  @override
  void didUpdateWidget(_StripItem old) {
    super.didUpdateWidget(old);
    if (old.item.path != widget.item.path) _draw();
  }

  /// A waiting photo's picture, once the photograph shown first has had its turn.
  void _draw() {
    if (!widget.item.waiting) return;
    final thumbnails = widget.editor.library.thumbnails;
    final path = widget.item.path;
    const edge = PhotoStripModel.thumbnailEdge;
    _thumbnail = thumbnails.peek(path, edge);
    if (_thumbnail != null) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (!mounted || widget.item.path != path) return;
      thumbnails.request(path, maxEdge: edge, wanted: () => mounted).then((image) {
        if (mounted && image != null && widget.item.path == path) {
          setState(() => _thumbnail = image);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final image = widget.item.doc?.importPicture ?? _thumbnail;
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
                    color: widget.selected ? palette.accent : const Color(0x00000000), width: 2),
                borderRadius: BorderRadius.circular(3),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: image == null
                    ? Container(
                        color: palette.canvas,
                        alignment: Alignment.center,
                        child: Text(widget.item.name,
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

/// One line clipped at its start, so a path's file name stays in view; the whole path on hover
/// (`.filmstrip-path`).
class _StartClipped extends StatelessWidget {
  const _StartClipped(this.text, {required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        bool fits(String line) => (TextPainter(
              text: TextSpan(text: line, style: style),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout()).width <= constraints.maxWidth;
        var shown = text;
        if (!fits(shown)) {
          // The longest end of the path that fits after an ellipsis.
          var low = 0, high = text.length;
          while (low < high) {
            final mid = (low + high) ~/ 2;
            if (fits('…${text.substring(mid)}')) {
              high = mid;
            } else {
              low = mid + 1;
            }
          }
          shown = '…${text.substring(low)}';
        }
        final line = Text(shown, maxLines: 1, softWrap: false, style: style);
        return shown == text ? line : HoverTip(message: text, child: line);
      });
}
