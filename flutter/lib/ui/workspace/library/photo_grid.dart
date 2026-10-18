// The library's grid: square tiles that stretch to fill the width, built only near the view, each
// with the file's picture, its name and stars, and badges for RAW, video and edited photos.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../model/editor.dart';
import '../../../model/host_thumbnails.dart';
import '../../../model/library_model.dart';
import '../../kit/kit.dart';
import '../../theme/theme.dart';
import '../picture.dart';

/// Rows of square cells that stretch to fill the width.
class GridLayout {
  GridLayout(double width, this.count, double tileSize) {
    final inner = math.max(0.0, width - padding * 2);
    columns = math.max(1, ((inner + gap) / (tileSize + gap)).floor());
    size = math.max(1.0, (inner - gap * (columns - 1)) / columns);
  }

  static const padding = 16.0, gap = 4.0;
  final int count;
  late final int columns;
  late final double size;
  double get row => size + gap;

  /// Where tile `index` starts, down the grid.
  double top(int index) => padding + (index ~/ columns) * row;
}

/// The hover tint over library rows and tiles (`--library-hover`).
Color libraryHover(Palette palette) =>
    palette.dark ? const Color(0x0AFFFFFF) : const Color(0x0A000000);

/// Where an opened photo's tile shows it, for the handoff to the viewer.
typedef TileOrigins = Map<String, LibraryHandoff? Function()>;

class PhotoGrid extends StatefulWidget {
  const PhotoGrid({
    super.key,
    required this.photos,
    required this.records,
    required this.tileSize,
    required this.thumbnails,
    required this.active,
    required this.selected,
    required this.focusKey,
    required this.focusNode,
    required this.origins,
    required this.onPress,
    required this.onOpen,
    required this.onRate,
    required this.onMenu,
    required this.onKey,
    required this.contentKey,
    this.empty,
  });

  final List<LibraryPhoto> photos;
  final LibraryRecords records;
  final double tileSize;
  final HostThumbnails thumbnails;

  /// Shown: hidden, the grid draws no pictures.
  final bool active;
  final Set<String> selected;
  final String? focusKey;
  final FocusNode focusNode;
  final TileOrigins origins;
  final void Function(String key, {required bool range, required bool toggle}) onPress;
  final ValueChanged<String> onOpen;
  final void Function(String key, int rating) onRate;
  final void Function(String key, Offset position) onMenu;
  final KeyEventResult Function(KeyEvent event, GridLayout layout, double viewport) onKey;

  /// The folder shown: a new one starts at the top.
  final String contentKey;
  final Widget? empty;

  @override
  State<PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<PhotoGrid> {
  final _scroll = ScrollController();
  GridLayout? _layout;
  double _viewport = 0;

  /// Whether the keyboard moved last, which shows the focus ring (`data-keyboard`).
  bool _keyboard = false;

  @override
  void didUpdateWidget(PhotoGrid old) {
    super.didUpdateWidget(old);
    if (old.contentKey != widget.contentKey && _scroll.hasClients) _scroll.jumpTo(0);
    if (old.focusKey != widget.focusKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the keyboard focus into view.
  void _reveal() {
    final layout = _layout;
    if (layout == null || !_scroll.hasClients) return;
    final index = widget.photos.indexWhere((p) => p.key == widget.focusKey);
    if (index < 0) return;
    final top = layout.top(index), offset = _scroll.offset;
    final max = _scroll.position.maxScrollExtent;
    if (top < offset) {
      _scroll.jumpTo(math.max(0, top - GridLayout.padding));
    } else if (top + layout.size > offset + _viewport) {
      _scroll.jumpTo(math.min(max, top + layout.size + GridLayout.padding - _viewport));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: (node, event) {
        final layout = _layout;
        if (layout == null) return KeyEventResult.ignored;
        final result = widget.onKey(event, layout, _viewport);
        if (result == KeyEventResult.handled && !_keyboard) setState(() => _keyboard = true);
        return result;
      },
      child: Listener(
        onPointerDown: (_) {
          if (_keyboard) setState(() => _keyboard = false);
        },
        child: LayoutBuilder(builder: (context, constraints) {
          final layout = _layout = GridLayout(constraints.maxWidth, widget.photos.length, widget.tileSize);
          _viewport = constraints.maxHeight;
          return Stack(children: [
            ThinScroll(
              controller: _scroll,
              child: GridView.builder(
                key: ValueKey(widget.contentKey),
                controller: _scroll,
                padding: const EdgeInsets.all(GridLayout.padding),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: layout.columns,
                  mainAxisSpacing: GridLayout.gap,
                  crossAxisSpacing: GridLayout.gap,
                ),
                itemCount: widget.photos.length,
                itemBuilder: (context, index) {
                  final photo = widget.photos[index];
                  final record = widget.records[photo.key];
                  return PhotoTile(
                    key: ValueKey(photo.key),
                    photo: photo,
                    size: layout.size,
                    selected: widget.selected.contains(photo.key),
                    focused: _keyboard && photo.key == widget.focusKey && widget.focusNode.hasFocus,
                    rating: (record?['rating'] as num?)?.toInt() ?? 0,
                    edited: record?['edit'] != null,
                    thumbnails: widget.active ? widget.thumbnails : null,
                    origins: widget.origins,
                    onPress: (range, toggle) {
                      widget.focusNode.requestFocus();
                      widget.onPress(photo.key, range: range, toggle: toggle);
                    },
                    onOpen: () => widget.onOpen(photo.key),
                    onRate: (rating) => widget.onRate(photo.key, rating),
                    onMenu: (position) {
                      widget.focusNode.requestFocus();
                      widget.onMenu(photo.key, position);
                    },
                  );
                },
              ),
            ),
            if (widget.empty != null) Positioned.fill(child: widget.empty!),
          ]);
        }),
      ),
    );
  }
}

class PhotoTile extends StatefulWidget {
  const PhotoTile({
    super.key,
    required this.photo,
    required this.size,
    required this.selected,
    required this.focused,
    required this.rating,
    required this.edited,
    required this.thumbnails,
    required this.origins,
    required this.onPress,
    required this.onOpen,
    required this.onRate,
    required this.onMenu,
  });

  final LibraryPhoto photo;
  final double size;
  final bool selected, focused, edited;
  final int rating;
  final HostThumbnails? thumbnails;
  final TileOrigins origins;
  final void Function(bool range, bool toggle) onPress;
  final VoidCallback onOpen;
  final ValueChanged<int> onRate;
  final ValueChanged<Offset> onMenu;

  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  final _thumb = GlobalKey();
  ui.Image? _image;

  /// The picture arrived while the tile was on show, so it fades in.
  bool _fresh = false;
  bool _none = false, _hovered = false;

  LibraryPhoto get photo => widget.photo;
  String get _stamp => '${photo.size}:${photo.modified}';

  @override
  void initState() {
    super.initState();
    widget.origins[photo.key] = _origin;
    _load();
  }

  @override
  void didUpdateWidget(PhotoTile old) {
    super.didUpdateWidget(old);
    if (old.photo.key != photo.key) widget.origins.remove(old.photo.key);
    widget.origins[photo.key] = _origin;
    if (old.photo.file != photo.file || old.photo.modified != photo.modified ||
        (old.thumbnails == null) != (widget.thumbnails == null)) {
      _load();
    }
  }

  @override
  void dispose() {
    if (widget.origins[photo.key] == _origin) widget.origins.remove(photo.key);
    super.dispose();
  }

  void _load() {
    final thumbnails = widget.thumbnails;
    if (thumbnails == null) return;
    final edge = PhotoLibrary.thumbnailEdge;
    final kept = thumbnails.peek(photo.file, edge, _stamp);
    if (kept != null) {
      _image = kept;
      _fresh = false;
      return;
    }
    _none = thumbnails.failed(photo.file, edge, _stamp);
    if (_none) return;
    final file = photo.file;
    thumbnails.request(file, maxEdge: edge, stamp: _stamp, wanted: () => mounted).then((image) {
      if (!mounted || photo.file != file) return;
      setState(() {
        _image = image ?? _image;
        _none = image == null && _image == null;
        _fresh = image != null;
      });
    });
  }

  /// The picture and where it is on screen, for the handoff.
  LibraryHandoff? _origin() {
    final image = _image;
    final box = _thumb.currentContext?.findRenderObject() as RenderBox?;
    if (image == null || box == null || !box.attached) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return LibraryHandoff(image: image, rect: rect, path: photo.file);
  }

  void _pointerDown(PointerDownEvent event) {
    final keys = HardwareKeyboard.instance;
    if (event.buttons == kSecondaryButton ||
        (event.buttons == kPrimaryButton && keys.isControlPressed && !keys.isMetaPressed)) {
      widget.onMenu(event.position);
    } else if (event.buttons == kPrimaryButton) {
      widget.onPress(keys.isShiftPressed, keys.isMetaPressed || keys.isControlPressed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final showName = widget.size > 150;
    final lit = _hovered || widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: _pointerDown,
            child: GestureDetector(
              onDoubleTap: widget.onOpen,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? palette.selected
                      : _hovered
                          ? libraryHover(palette)
                          : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(6),
                ),
                // The keyboard's ring sits inside the tile without moving its picture.
                foregroundDecoration: widget.focused
                    ? BoxDecoration(
                        border: Border.all(color: palette.accent, width: 2),
                        borderRadius: BorderRadius.circular(6))
                    : null,
                child: Column(children: [
                  Expanded(child: _picture(palette)),
                  SizedBox(
                    height: 28,
                    child: Row(children: [
                      if (showName)
                        Expanded(
                          child: Text(photo.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: editorText(context,
                                  size: TextSizes.label,
                                  color: widget.selected ? palette.text : palette.muted)),
                        )
                      else
                        const Spacer(),
                      // Room for the stars, which sit over the tile.
                      const SizedBox(width: 5 * 15.0),
                      if (!showName) const Spacer(),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
        Positioned(
          right: showName ? 8 : null,
          left: showName ? null : 0,
          width: showName ? null : widget.size,
          bottom: 0,
          height: 28,
          child: Center(
            child: _Stars(rating: widget.rating, shown: lit, onRate: widget.onRate),
          ),
        ),
        if (widget.edited || photo.kind != 'image')
          Positioned(
            top: 13,
            right: 13,
            child: IgnorePointer(
              child: Row(children: [
                if (photo.kind == 'raw') _Badge(text: 'RAW', shown: lit),
                if (photo.kind == 'video') _Badge(text: 'Video', shown: lit),
                if (widget.edited) const _Badge(icon: 'edited', shown: true),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _picture(Palette palette) {
    final image = _image;
    if (image == null) {
      return Center(
        child: FractionallySizedBox(
          widthFactor: .76,
          child: AspectRatio(
            aspectRatio: 3 / 2,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.dark ? const Color(0x0AFFFFFF) : const Color(0x09000000),
                borderRadius: BorderRadius.circular(2),
              ),
              child: _none
                  ? Text(photo.name.split('.').last.toUpperCase(),
                      style: editorText(context,
                              size: TextSizes.caption, weight: FontWeight.w600, color: palette.muted)
                          .copyWith(letterSpacing: .8))
                  : null,
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      // The picture fitted inside the cell, with the shadow around the picture itself.
      final scale = math.min(constraints.maxWidth / image.width, constraints.maxHeight / image.height);
      final size = Size(image.width * scale, image.height * scale);
      final picture = Container(
        key: _thumb,
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          boxShadow: palette.dark
              ? const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1)),
                  BoxShadow(color: Color(0x14FFFFFF), spreadRadius: .5),
                ]
              : const [
                  BoxShadow(color: Color(0x2E000000), blurRadius: 2, offset: Offset(0, 1)),
                  BoxShadow(color: Color(0x1F000000), spreadRadius: .5),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: EnginePicture(image, fit: BoxFit.fill),
        ),
      );
      return Center(
        child: !_fresh
            ? picture
            : TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 220),
                curve: const Cubic(.2, .8, .2, 1),
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.scale(scale: .985 + .015 * t, child: child),
                ),
                child: picture,
              ),
      );
    });
  }
}

/// Five stars: a click rates, a click on the rating clears it. Unrated stars show while the
/// tile is hovered or selected.
class _Stars extends StatelessWidget {
  const _Stars({required this.rating, required this.shown, required this.onRate});
  final int rating;
  final bool shown;
  final ValueChanged<int> onRate;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var value = 1; value <= 5; value++)
          _Star(
            on: value <= rating,
            shown: shown || value <= rating,
            label: '$value star${value > 1 ? 's' : ''}',
            onTap: () => onRate(value == rating ? 0 : value),
          ),
      ]);
}

class _Star extends StatefulWidget {
  const _Star({required this.on, required this.shown, required this.label, required this.onTap});
  final bool on, shown;
  final String label;
  final VoidCallback onTap;

  @override
  State<_Star> createState() => _StarState();
}

class _StarState extends State<_Star> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Semantics(
      label: widget.label,
      button: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: widget.shown ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: AppIcon(widget.on ? 'starFilled' : 'star',
                  size: 13,
                  color: _hovered ? palette.accent : (widget.on ? palette.text : palette.muted)),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({this.text, this.icon, required this.shown});
  final String? text, icon;
  final bool shown;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: shown ? 1 : 0,
        child: Container(
          margin: const EdgeInsets.only(left: 4),
          padding: EdgeInsets.symmetric(horizontal: icon != null ? 3 : 5, vertical: 2),
          decoration: BoxDecoration(
              color: const Color(0xB31F2023), borderRadius: BorderRadius.circular(4)),
          child: icon != null
              ? AppIcon(icon!, size: 12, color: const Color(0xFFFFFFFF))
              : Text(text!,
                  style: editorText(context,
                          size: 9.5, weight: FontWeight.w600, color: const Color(0xFFFFFFFF))
                      .copyWith(letterSpacing: .4)),
        ),
      );
}
