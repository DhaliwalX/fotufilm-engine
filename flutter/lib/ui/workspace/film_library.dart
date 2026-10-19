// The film library, compact: Films and Presets, a search field and the film type, and a row for
// each film with the photograph developed on it. Collapsed, it is a column of pictures; on a
// phone, a strip of them to swipe through.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/negative_document.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'editing_dialogs.dart';
import 'panel_layout.dart';
import 'picture.dart';
import 'preset_list.dart';

class FilmLibrary extends StatefulWidget {
  const FilmLibrary({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<FilmLibrary> createState() => _FilmLibraryState();
}

class _FilmLibraryState extends State<FilmLibrary> {
  final _scroll = ScrollController();
  final _strip = ScrollController();
  final _search = TextEditingController();

  /// Whether the strip has been brought round to the chosen film since the dock opened.
  bool _stripPlaced = false;

  @override
  void dispose() {
    _scroll.dispose();
    _strip.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Normal (null) first, then the films of the chosen type whose names match the search.
  List<Json?> _films() {
    final editor = widget.editor;
    final query = editor.search.trim().toLowerCase();
    bool matches(Json? stock) =>
        editor.filmType.holds(stock) &&
        (query.isEmpty ||
            (stock?['name'] as String? ?? 'normal').toLowerCase().contains(query));
    // A negative is read only as a film that has a negative.
    final negative = isNegative(editor.edit);
    return [
      if (matches(null)) null,
      for (final s in editor.stocks)
        if (matches(s) && (!negative || readsNegative(s))) s,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final open = editor.filmOpen;
    return ColoredBox(
      color: Palette.of(context).panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: Metrics.libraryHeadingHeight,
          child: Padding(
            padding: open ? Metrics.libraryHeadingPadding : EdgeInsets.zero,
            child: Row(
              mainAxisAlignment: open ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                if (open) ...[
                  Expanded(
                    child: SegmentedControl<bool>(
                      items: const [(false, 'Films'), (true, 'Presets')],
                      selected: editor.presetsTab,
                      onChanged: (presets) {
                        // Each tab keeps its own search.
                        _search.text = presets ? editor.presets.search : editor.search;
                        editor.setPresetsTab(presets);
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                FilmSettingsButton(editor: editor),
                FilmSidebarToggle(editor: editor),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: Metrics.searchPadding,
            child: Row(children: [
              Expanded(
                child: _SearchField(
                  controller: _search,
                  placeholder: editor.presetsTab ? 'Search presets' : 'Search films',
                  onChanged: editor.presetsTab ? editor.presets.setSearch : editor.setSearch,
                ),
              ),
              if (editor.presetsTab) ...[
                const SizedBox(width: 4),
                QuietButton(
                  icon: 'plus',
                  tooltip: 'Save Preset…',
                  onPressed:
                      editor.active == null ? null : () => showSavePresetDialog(context, editor),
                ),
              ],
              if (!editor.presetsTab && editor.filmTypes.length > 1) ...[
                const SizedBox(width: 6),
                _FilmTypePicker(
                  types: editor.filmTypes,
                  selected: editor.filmType,
                  onChanged: editor.setFilmType,
                ),
              ],
            ]),
          ),
        Expanded(child: editor.presetsTab ? PresetList(editor: editor, open: open) : _list(open)),
      ]),
    );
  }

  Widget _list(bool open) {
    final editor = widget.editor;
    final films = _films();
    if (films.isEmpty) return const LibraryEmpty('No matching films.');
    final selected = editor.edit['stock'] as String?;
    final doc = editor.active;
    if (editor.layout.compact) return _filmStrip(films, selected);
    return ThinScroll(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        // Rows are built as they come into view, which is when their pictures develop.
        cacheExtent: 0,
        padding: open ? Metrics.stockListPadding : Metrics.stockListCollapsedPadding,
        itemCount: films.length,
        itemBuilder: (context, index) {
          final stock = films[index];
          final id = stock?['id'] as String?;
          return Padding(
            padding: EdgeInsets.only(
                bottom: stock == null ? Metrics.normalRowGap : Metrics.stockRowGap),
            child: _ShownRow(
              editor: editor,
              id: id ?? '',
              child: StockRow(
              name: stock?['name'] as String? ?? 'Normal',
              kind: stock == null ? 'No film' : 'Film',
              thumbnail: doc?.filmThumbnails[id ?? ''] ?? doc?.importPicture,
              selected: id == selected,
              compact: !open,
              onPressed: doc == null ? null : () => editor.chooseStock(id),
            ),
            ),
          );
        },
      ),
    );
  }

  /// The phone's strip: a tile for each film, swiped across, opening on the chosen one.
  Widget _filmStrip(List<Json?> films, String? selected) {
    final editor = widget.editor;
    final doc = editor.active;
    const extent = Metrics.filmStripTile + Metrics.filmStripGap;
    if (!_stripPlaced) {
      _stripPlaced = true;
      final index = films.indexWhere((s) => s?['id'] == selected);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_strip.hasClients || index <= 0) return;
        final position = _strip.position;
        _strip.jumpTo((index * extent - (position.viewportDimension - extent) / 2)
            .clamp(0, position.maxScrollExtent));
      });
    }
    return ListView.builder(
      controller: _strip,
      scrollDirection: Axis.horizontal,
      // Tiles are built as they come into view, which is when their pictures develop.
      cacheExtent: 0,
      itemExtent: extent,
      padding: Metrics.filmStripPadding,
      itemCount: films.length,
      itemBuilder: (context, index) {
        final stock = films[index];
        final id = stock?['id'] as String?;
        return Padding(
          padding: const EdgeInsets.only(right: Metrics.filmStripGap),
          child: _ShownRow(
            editor: editor,
            id: id ?? '',
            child: StripTile(
              name: stock?['name'] as String? ?? 'Normal',
              thumbnail: doc?.filmThumbnails[id ?? ''] ?? doc?.importPicture,
              selected: id == selected,
              onPressed: doc == null ? null : () => editor.chooseStock(id),
            ),
          ),
        );
      },
    );
  }
}

/// One film in the phone's strip: its picture, ringed while chosen, over its name.
class StripTile extends StatelessWidget {
  const StripTile({
    super.key,
    required this.name,
    required this.thumbnail,
    required this.selected,
    required this.onPressed,
  });

  final String name;
  final ui.Image? thumbnail;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Column(children: [
          Container(
            height: Metrics.filmStripThumb,
            decoration: BoxDecoration(
              color: palette.dark ? const Color(0x08FFFFFF) : const Color(0x07000000),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: selected ? palette.accent : const Color(0x00000000), width: 2),
            ),
            padding: const EdgeInsets.all(2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox.expand(
                child: thumbnail != null
                    ? EnginePicture(thumbnail!, fit: BoxFit.cover)
                    : const Center(child: AppIcon('film', size: 18, color: Color(0xFF8D9097))),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: editorText(context,
                  size: TextSizes.label,
                  weight: selected ? FontWeight.w700 : FontWeight.w500,
                  height: 1.2)),
        ]),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.placeholder, required this.onChanged});
  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      height: Metrics.control,
      decoration: BoxDecoration(
          color: palette.fieldFill, borderRadius: BorderRadius.circular(Metrics.control / 2)),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        AppIcon('search', size: 15, color: palette.text.withValues(alpha: .8)),
        const SizedBox(width: 6),
        Expanded(
          child: EditableField(
            controller: controller,
            style: editorText(context),
            placeholder: placeholder,
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }
}

/// The film type the list shows: a compact filled button with the type's name, and a menu of
/// the types under it.
class _FilmTypePicker extends StatefulWidget {
  const _FilmTypePicker({required this.types, required this.selected, required this.onChanged});
  final List<FilmType> types;
  final FilmType selected;
  final ValueChanged<FilmType> onChanged;

  @override
  State<_FilmTypePicker> createState() => _FilmTypePickerState();
}

class _FilmTypePickerState extends State<_FilmTypePicker> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final filtered = widget.selected != FilmType.all;
    return HoverTip(
      message: 'Film type',
      child: Builder(
        builder: (anchor) => tinted(
          opensMenu: true,
          label: 'Film type',
          value: widget.selected.title,
          onTap: () => showMenu(anchor, alignEnd: true, width: 170, [
            for (final type in widget.types)
              MenuItem(
                label: type.title,
                checked: type == widget.selected,
                onSelected: () => widget.onChanged(type),
              ),
          ]),
          child: Container(
            height: Metrics.control,
            constraints: const BoxConstraints(maxWidth: 104),
            padding: const EdgeInsets.only(left: 8, right: 4),
            decoration: BoxDecoration(
              color: filtered ? palette.gray800 : (hovered ? palette.pressed : palette.fieldFill),
              borderRadius: BorderRadius.circular(Metrics.control / 2),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(widget.selected.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: editorText(context,
                        color: filtered ? palette.onSelected : palette.text)),
              ),
              AppIcon('chevronDown',
                  size: 14, color: filtered ? palette.onSelected : palette.text),
            ]),
          ),
        ),
      ),
    );
  }
}

class LibraryEmpty extends StatelessWidget {
  const LibraryEmpty(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(text, style: editorText(context, color: Palette.of(context).muted)),
      );
}

/// One film: a quiet toggle the width of the list, its picture, its name and kind.
class StockRow extends StatefulWidget {
  const StockRow({
    super.key,
    required this.name,
    required this.kind,
    required this.thumbnail,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  final String name, kind;
  final ui.Image? thumbnail;
  final bool selected, compact;
  final VoidCallback? onPressed;

  @override
  State<StockRow> createState() => _StockRowState();
}

class _StockRowState extends State<StockRow> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final fg = widget.selected ? palette.onSelected : palette.text;
    final thumb = widget.compact ? Metrics.stockThumbCollapsed : Metrics.stockThumb;
    final row = tinted(
      onTap: widget.onPressed,
      selected: widget.selected,
      child: Container(
        constraints: const BoxConstraints(minHeight: Metrics.stockRowMinHeight),
        padding: widget.compact ? const EdgeInsets.all(3) : Metrics.stockRowPadding,
        decoration: BoxDecoration(
          color: widget.selected
              ? palette.gray800
              : hovered && widget.onPressed != null
                  ? palette.hover
                  : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Container(
            width: thumb.width,
            height: thumb.height,
            decoration: BoxDecoration(
              color: palette.dark ? const Color(0x08FFFFFF) : const Color(0x07000000),
              borderRadius: BorderRadius.circular(3),
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.thumbnail != null
                ? EnginePicture(widget.thumbnail!, fit: BoxFit.contain)
                : const Center(child: AppIcon('film', size: 18, color: Color(0xFF8D9097))),
          ),
          if (!widget.compact) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name,
                    style: editorText(context, weight: FontWeight.w500, color: fg, height: 1.2)),
                const SizedBox(height: 1),
                Text(widget.kind,
                    style: editorText(context,
                        size: TextSizes.caption,
                        color: widget.selected ? fg.withValues(alpha: .55) : palette.muted)),
              ]),
            ),
          ],
        ]),
      ),
    );
    return widget.compact ? HoverTip(message: widget.name, child: row) : row;
  }
}

/// Tells the editor while a film row is on screen, so only shown rows develop their pictures.
class _ShownRow extends StatefulWidget {
  const _ShownRow({required this.editor, required this.id, required this.child});
  final EditorModel editor;
  final String id;
  final Widget child;

  @override
  State<_ShownRow> createState() => _ShownRowState();
}

class _ShownRowState extends State<_ShownRow> {
  @override
  void initState() {
    super.initState();
    widget.editor.showFilmRow(widget.id, true);
  }

  @override
  void didUpdateWidget(_ShownRow old) {
    super.didUpdateWidget(old);
    if (old.id == widget.id) return;
    widget.editor
      ..showFilmRow(old.id, false)
      ..showFilmRow(widget.id, true);
  }

  @override
  void dispose() {
    widget.editor.showFilmRow(widget.id, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
