// The photos chosen in the strip below the canvas, which Paste Settings and presets apply to
// (web/src/editor/strip-selection.js, useStripSelection.js). A click shows a photo and chooses it
// alone; Shift-click and ⌘-click choose more without changing the one shown, as the library
// grid's clicks do. The shown photo is always among them.
import 'editor.dart';

/// Chosen keys and the one a Shift-click spans from.
class Selection<T> {
  Selection(Iterable<T> selected, this.anchor) : selected = Set.unmodifiable(selected);
  Selection.start(T? shown) : this([?shown], shown);
  final Set<T> selected;
  final T? anchor;
}

/// The selection after pressing `key` among `keys`, with `range` (Shift) or `toggle` (⌘)
/// (photo-library/library-model.js `nextSelection`).
Selection<T> nextSelection<T>(List<T> keys, Selection<T> current, T key,
    {bool range = false, bool toggle = false}) {
  final anchor = current.anchor;
  if (range && anchor != null) {
    final from = keys.indexOf(anchor), to = keys.indexOf(key);
    if (from >= 0 && to >= 0) {
      final span = keys.sublist(from < to ? from : to, (from < to ? to : from) + 1);
      return Selection(toggle ? {...current.selected, ...span} : span, anchor);
    }
  }
  if (toggle) {
    final next = {...current.selected};
    if (!next.remove(key)) next.add(key);
    return Selection(next, key);
  }
  return Selection({key}, key);
}

/// The keys chosen among `keys`: the shown one and the others still open.
Set<T> chosenKeys<T>(List<T> keys, T? shown, Selection<T> selection) => {
      for (final k in keys)
        if (selection.selected.contains(k) || k == shown) k,
    };

/// The selection after a modified press on `key`; a plain press starts again from the shown one.
Selection<T> pressedStrip<T>(List<T> keys, T? shown, Selection<T> selection, T key,
    {bool range = false, bool toggle = false}) {
  if (!range && !toggle) return Selection.start(null);
  final current = Selection(chosenKeys(keys, shown, selection), selection.anchor ?? shown);
  final next = nextSelection(keys, current, key, range: range, toggle: toggle);
  // The photo shown stays chosen: ⌘-click on it leaves the selection as it was.
  if (shown != null && !next.selected.contains(shown)) return current;
  return next;
}

/// The strip's selection of the open photographs.
class StripSelection {
  StripSelection(this.editor);
  final EditorModel editor;

  Selection<PhotoDocument> _selection = Selection.start(null);

  /// The open photographs the strip shows: those in the shown photo's folder, in its order.
  List<PhotoDocument> get _shown => [for (final item in editor.strip.items) ?item.doc];

  /// The chosen photos, in the strip's order; the shown one alone unless more were chosen.
  List<PhotoDocument> get chosen {
    final shown = _shown;
    final keys = chosenKeys(shown, editor.active, _current);
    return [for (final d in shown) if (keys.contains(d)) d];
  }

  /// Whether `doc` is chosen with others (the strip rings it).
  bool isChosen(PhotoDocument doc) => chosen.length > 1 && chosen.contains(doc);

  /// Showing another photo by any way but a modified click chooses it alone.
  Selection<PhotoDocument> get _current {
    final shown = editor.active;
    if (shown != null && !_selection.selected.contains(shown)) {
      _selection = Selection.start(shown);
    }
    return _selection;
  }

  /// A click on a photo of the strip: Shift spans, ⌘ toggles, a plain click shows it.
  void press(PhotoDocument doc, {bool range = false, bool toggle = false}) {
    if (editor.exporting) return;
    _selection = pressedStrip(_shown, editor.active, _current, doc,
        range: range, toggle: toggle);
    if (!range && !toggle) {
      editor.selectDocument(editor.documents.indexOf(doc));
      _selection = Selection.start(doc);
    }
    editor.notify();
  }

  /// ⌘A: every open photo the strip shows.
  void selectAll() {
    final shown = _shown;
    if (shown.length < 2) return;
    _selection = Selection(shown, editor.active);
    editor.notify();
  }

  /// Esc: the shown photo alone.
  void clear() {
    if (_selection.selected.length <= 1) return;
    _selection = Selection.start(editor.active);
    editor.notify();
  }
}
