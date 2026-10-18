// The film library's Presets tab (web/src/editor/FilmLibrary.jsx, PresetRow.jsx): a row for each
// preset whose name matches the search, with the photograph developed as the preset would leave
// it, as a film's row is with only the film swapped. A row reads chosen while applying it again
// would change nothing; a click applies it to the photos chosen in the strip.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'film_library.dart';

class PresetList extends StatefulWidget {
  const PresetList({super.key, required this.editor, required this.open});
  final EditorModel editor;
  final bool open;

  @override
  State<PresetList> createState() => _PresetListState();
}

class _PresetListState extends State<PresetList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final presets = editor.presets;
    if (presets.list.isEmpty) return LibraryEmpty(widget.open ? 'No presets yet.' : '');
    final visible = presets.visible;
    if (visible.isEmpty) return const LibraryEmpty('No matching presets.');
    final doc = editor.active;
    return ThinScroll(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: widget.open ? Metrics.stockListPadding : Metrics.stockListCollapsedPadding,
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final preset = visible[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: Metrics.stockRowGap),
            child: StockRow(
              name: preset.name,
              kind: presets.kind(preset),
              thumbnail: doc?.presetThumbnails[preset.id],
              selected: presets.standing(preset),
              compact: !widget.open,
              onPressed: doc == null || editor.exporting
                  ? null
                  : () => presets.applyPreset(preset.id),
            ),
          );
        },
      ),
    );
  }
}
