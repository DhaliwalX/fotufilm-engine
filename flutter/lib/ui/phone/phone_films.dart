// The Film Strip's Films page: the film types as shelves of chips, and a strip of tiles with the
// photograph developed on each film, the chosen one's name in the accent.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import '../workspace/film_library.dart';
import '../workspace/picture.dart';

class PhoneFilms extends StatefulWidget {
  const PhoneFilms({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<PhoneFilms> createState() => _PhoneFilmsState();
}

class _PhoneFilmsState extends State<PhoneFilms> {
  final _strip = ScrollController();

  /// Whether the strip has been brought round to the chosen film since it was shown.
  bool _placed = false;

  @override
  void dispose() {
    _strip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final films = libraryFilms(editor);
    final selected = editor.edit['stock'] as String?;
    final doc = editor.active;
    const extent = PhoneMetrics.filmTile + PhoneMetrics.filmGap;
    if (!_placed) {
      _placed = true;
      final index = films.indexWhere((s) => s?['id'] == selected);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_strip.hasClients || index <= 0) return;
        final position = _strip.position;
        _strip.jumpTo((index * extent - (position.viewportDimension - extent) / 2)
            .clamp(0, position.maxScrollExtent));
      });
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (editor.filmTypes.length > 1)
        SizedBox(
          height: PhoneMetrics.chips,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final type in editor.filmTypes)
                PhoneChip(
                  label: type.title,
                  selected: type == editor.filmType,
                  onPressed: () {
                    _placed = false;
                    editor.setFilmType(type);
                  },
                ),
            ],
          ),
        ),
      const SizedBox(height: 10),
      SizedBox(
        height: PhoneMetrics.filmTile + 30,
        child: films.isEmpty
            ? const LibraryEmpty('No films of this type.')
            : ListView.builder(
                controller: _strip,
                scrollDirection: Axis.horizontal,
                // Tiles are built as they come into view, which is when their pictures develop.
                scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                itemExtent: extent,
                itemCount: films.length,
                itemBuilder: (context, index) {
                  final stock = films[index];
                  final id = stock?['id'] as String?;
                  return Padding(
                    padding: const EdgeInsets.only(right: PhoneMetrics.filmGap),
                    child: ShownFilmRow(
                      editor: editor,
                      id: id ?? '',
                      child: _FilmTile(
                        name: stock?['name'] as String? ?? 'Normal',
                        positive: stock?['reversal'] == true,
                        thumbnail: doc?.filmThumbnails[id ?? ''] ?? doc?.importPicture,
                        selected: id == selected,
                        onPressed: doc == null ? null : () => editor.chooseStock(id),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

/// A film: the photograph developed on it in a rounded square, over its name in caps.
class _FilmTile extends StatelessWidget {
  const _FilmTile({
    required this.name,
    required this.positive,
    required this.thumbnail,
    required this.selected,
    required this.onPressed,
  });

  final String name;
  final bool positive, selected;
  final ui.Image? thumbnail;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    const side = PhoneMetrics.filmTile;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Column(children: [
          ClipRRect(
            // The corners round by about a fifth of the side.
            borderRadius: BorderRadius.circular(side * .226),
            child: Container(
              width: side,
              height: side,
              color: const Color(0x14FFFFFF),
              child: thumbnail != null
                  ? EnginePicture(thumbnail!, fit: BoxFit.cover)
                  : const Center(child: AppIcon('film', size: 22, color: Color(0xFF8D9097))),
            ),
          ),
          const SizedBox(height: 6),
          Text(name.toUpperCase(),
              maxLines: positive ? 1 : 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: capsText(context,
                  color: selected ? palette.accent : palette.text.withValues(alpha: .7))),
          if (positive)
            Text('Direct Positive',
                maxLines: 1,
                style: editorText(context,
                    size: TextSizes.caption, color: palette.text.withValues(alpha: .45))),
        ]),
      ),
    );
  }
}

/// A shelf's chip: plain text, filled while chosen.
class PhoneChip extends StatelessWidget {
  const PhoneChip(
      {super.key, required this.label, required this.selected, required this.onPressed});
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF3C3C3C) : null,
            borderRadius: BorderRadius.circular(PhoneMetrics.chips / 2),
          ),
          child: Text(label,
              style: editorText(context,
                  size: TextSizes.section,
                  weight: FontWeight.w500,
                  color: selected ? palette.text : palette.text.withValues(alpha: .6))),
        ),
      ),
    );
  }
}
