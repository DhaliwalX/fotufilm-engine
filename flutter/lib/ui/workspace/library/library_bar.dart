// The bar over the grid: what is shown and how many, then the search, the order, the least rating,
// Edited only, the tile size and Open.
import 'package:flutter/widgets.dart';

import '../../../model/library_model.dart';
import '../../kit/kit.dart';
import '../../theme/theme.dart';
import 'library_folders.dart' show formatCount;

/// The grid's filters.
typedef LibraryFilters = ({String search, String sort, int minRating, bool editedOnly});

const noFilters = (search: '', sort: 'name', minRating: 0, editedOnly: false);

class LibraryBar extends StatefulWidget {
  const LibraryBar({
    super.key,
    required this.title,
    required this.shown,
    required this.selected,
    required this.filters,
    required this.onFilters,
    required this.tileSize,
    required this.onTileSize,
    required this.onOpen,
  });

  final String title;
  final int shown, selected;
  final LibraryFilters filters;
  final ValueChanged<LibraryFilters> onFilters;
  final double tileSize;
  final ValueChanged<double> onTileSize;
  final VoidCallback onOpen;

  @override
  State<LibraryBar> createState() => _LibraryBarState();
}

class _LibraryBarState extends State<LibraryBar> {
  late final _search = TextEditingController(text: widget.filters.search);

  @override
  void didUpdateWidget(LibraryBar old) {
    super.didUpdateWidget(old);
    // Clear Filters empties the field.
    if (widget.filters.search != _search.text) _search.text = widget.filters.search;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final f = widget.filters;
    final count = widget.selected > 1
        ? '${formatCount(widget.selected)} of ${formatCount(widget.shown)} selected'
        : '${formatCount(widget.shown)} ${widget.shown == 1 ? 'photo' : 'photos'}';
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(children: [
        Flexible(
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(
              child: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: editorText(context, size: TextSizes.section, weight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Text(count, style: editorText(context, size: TextSizes.label, color: palette.muted)),
          ]),
        ),
        const SizedBox(width: 16),
        // The search gives way first in a narrow window.
        Flexible(
          flex: 2,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 168),
            child: _SearchField(
              controller: _search,
              onChanged: (search) => widget.onFilters((
                search: search,
                sort: f.sort,
                minRating: f.minRating,
                editedOnly: f.editedOnly,
              )),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 132,
          child: PickerField<String>(
            value: f.sort,
            options: [for (final (id, label) in librarySorts) PickerOption(id, label)],
            onChanged: (sort) => widget.onFilters(
                (search: f.search, sort: sort, minRating: f.minRating, editedOnly: f.editedOnly)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 132,
          child: PickerField<int>(
            value: f.minRating,
            options: [for (final (id, label) in libraryRatings) PickerOption(id, label)],
            onChanged: (minRating) => widget.onFilters(
                (search: f.search, sort: f.sort, minRating: minRating, editedOnly: f.editedOnly)),
          ),
        ),
        const SizedBox(width: 8),
        QuietButton(
          label: 'Edited',
          selected: f.editedOnly,
          onPressed: () => widget.onFilters(
              (search: f.search, sort: f.sort, minRating: f.minRating, editedOnly: !f.editedOnly)),
        ),
        const SizedBox(width: 8),
        HoverTip(
          message: 'Thumbnail size',
          child: SizedBox(
            width: 88,
            child: TrackSlider(
              value: widget.tileSize,
              min: 96,
              max: 280,
              onChanged: (size) => widget.onTileSize((size / 4).round() * 4.0),
            ),
          ),
        ),
        const SizedBox(width: 8),
        PillButton(
          widget.selected > 1 ? 'Open ${formatCount(widget.selected)}' : 'Open',
          variant: ButtonVariant.accent,
          onPressed: widget.selected > 0 ? widget.onOpen : null,
        ),
      ]),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
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
            placeholder: 'Search',
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }
}
