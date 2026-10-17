// The open photographs (web/src/editor/PhotoStrip.jsx), compact: the shown one's path, then a
// row of frames, the shown one ringed in the accent, each closed by the button on its corner.
// Photos that came with one (its folder, its roll) wait in the strip undecoded, showing the
// engine's picture of the file, drawn once their frame is on screen; one is imported when chosen.
// Shift-click and ⌘-click choose more open photos for Paste Settings and presets
// (strip_selection.dart); those chosen with the shown one are ringed in a fainter accent.
// The strip holds the shown photo's folder; scrolled away from its frame, a button at its top
// right brings the frame back.
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/library_model.dart' show stripPath;
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'picture.dart';

class PhotoStrip extends StatefulWidget {
  const PhotoStrip({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<PhotoStrip> createState() => _PhotoStripState();
}

class _PhotoStripState extends State<PhotoStrip> {
  EditorModel get editor => widget.editor;
  final _scroll = ScrollController();

  /// Each frame's slot: the frame, the room its close button takes, and the gap to the next.
  static final _stride = Metrics.stripItem.width + 6 + 6;

  /// The photo the strip last brought into view, and how many photos it held then.
  String? _shown;
  int _count = 0;

  /// Whether the shown photo's frame is scrolled out of view.
  bool _away = false;

  @override
  void initState() {
    super.initState();
    editor.addListener(_shownChanged);
    editor.strip.addListener(_stripChanged);
    _scroll.addListener(_scrolled);
  }

  @override
  void dispose() {
    editor.removeListener(_shownChanged);
    editor.strip.removeListener(_stripChanged);
    _scroll.dispose();
    super.dispose();
  }

  // The shown photo's frame stays in view: when another photo is shown, or the strip fills with
  // a folder or a roll around it. The editor speaks on every edit, so only the path is compared.
  void _shownChanged() {
    final path = editor.active?.path;
    if (path == _shown) return;
    _shown = path;
    _follow();
  }

  void _stripChanged() {
    final count = editor.strip.items.length;
    if (count == _count) return;
    _count = count;
    _follow();
  }

  void _follow() {
    final path = _shown;
    if (path != null) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(path));
  }

  void _scrolled() {
    final away = _shownOutOfView();
    if (away != _away) setState(() => _away = away);
  }

  bool _shownOutOfView() {
    if (!_scroll.hasClients) return false;
    final index = editor.strip.items.indexWhere((i) => i.path == _shown);
    if (index < 0) return false;
    final position = _scroll.position, start = index * _stride;
    return start + _stride <= position.pixels ||
        start >= position.pixels + position.viewportDimension;
  }

  void _reveal(String path) {
    if (!mounted || !_scroll.hasClients) return;
    final index = editor.strip.items.indexWhere((i) => i.path == path);
    if (index < 0) return;
    final position = _scroll.position;
    final start = index * _stride, end = start + _stride;
    final view = position.viewportDimension;
    if (start >= position.pixels && end <= position.pixels + view) return _scrolled();
    final target = (start - (view - _stride) / 2).clamp(0.0, position.maxScrollExtent);
    // A step to a neighbour glides; a jump across the roll goes straight there.
    if ((target - position.pixels).abs() <= view) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([editor.strip, editor]),
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
        Stack(clipBehavior: Clip.none, children: [
          Padding(
            padding: EdgeInsets.only(right: _away ? 24 : 0),
            child: _StartClipped(active == null ? '' : stripPath(active.path),
                style: editorText(context, size: TextSizes.caption, color: palette.muted, height: 1.3)),
          ),
          if (_away && _shown != null)
            Positioned(
              top: -4,
              right: 0,
              child: QuietButton(
                icon: 'locate',
                tooltip: 'Show Current Photo',
                size: 20,
                iconSize: 14,
                onPressed: () => _reveal(_shown!),
              ),
            ),
        ]),
        const SizedBox(height: 2),
        SizedBox(
          height: Metrics.stripItem.height + 6,
          child: ListView.builder(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            // Frames are built as they come into view, which is when waiting ones are drawn.
            cacheExtent: 0,
            itemExtent: _stride,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final doc = item.doc;
              return Align(
                alignment: Alignment.centerLeft,
                child: _StripItem(
                  key: ValueKey(item.path),
                  editor: editor,
                  item: item,
                  selected: doc != null && doc == active,
                  chosen: doc != null && editor.selection.isChosen(doc),
                  onTap: () {
                    final keys = HardwareKeyboard.instance;
                    final range = keys.isShiftPressed;
                    final toggle = keys.isMetaPressed || keys.isControlPressed;
                    // A modified click chooses among open photos; a waiting one opens first.
                    if (doc != null && (range || toggle)) {
                      editor.selection.press(doc, range: range, toggle: toggle);
                    } else {
                      editor.strip.choose(item);
                    }
                  },
                  onClose: () => editor.strip.close(item),
                ),
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
    required this.chosen,
    required this.onTap,
    required this.onClose,
  });
  final EditorModel editor;
  final StripItem item;
  final bool selected, chosen;
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
