// The photo library over the editor's panels: the folders on the left, and the bar and grid of the
// folder chosen. The grid's scope, filters, tile size, selection and keyboard focus are kept here;
// the folders, photos and ratings are the model's (PhotoLibrary).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../app/host_window.dart';
import '../../../model/editor.dart';
import '../../../model/library_files.dart';
import '../../../model/library_model.dart';
import '../../kit/kit.dart';
import '../../theme/theme.dart';
import 'library_bar.dart';
import 'library_dialogs.dart';
import 'library_folders.dart';
import 'photo_grid.dart';

class PhotoLibraryView extends StatefulWidget {
  const PhotoLibraryView({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<PhotoLibraryView> createState() => _PhotoLibraryViewState();
}

class _PhotoLibraryViewState extends State<PhotoLibraryView> {
  static const _tileSizeKey = 'library.tileSize';
  static const _ease = Cubic(.2, .8, .2, 1);

  PhotoLibrary get library => widget.editor.library;

  LibraryScope _scope = (folderId: allFolders, path: '');
  LibraryFilters _filters = noFilters;
  late double _tileSize = (widget.editor.settings.get<num>(_tileSizeKey) ?? 168).toDouble();
  LibrarySelection _selection = const LibrarySelection();
  String? _focusKey;
  final _grid = FocusNode(debugLabel: 'library grid');
  final TileOrigins _origins = {};

  /// Mounted once first shown, then kept so its place and selection last.
  bool _shown = false;

  // The sorted photos, kept while the lists, order and ratings they came from are the same.
  List<List<LibraryPhoto>>? _sortedFrom;
  String? _sortedBy;
  LibraryRecords? _sortedRecords;
  List<LibraryPhoto> _sorted = const [];

  @override
  void initState() {
    super.initState();
    library.addListener(_changed);
  }

  @override
  void dispose() {
    library.removeListener(_changed);
    _grid.dispose();
    super.dispose();
  }

  bool _wasOpen = false;

  void _changed() {
    if (library.open && !_shown) _shown = true;
    setState(() {});
    // Shown, the grid takes the keyboard.
    if (library.open && !_wasOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _grid.requestFocus());
    }
    _wasOpen = library.open;
  }

  List<LibraryPhoto> _sortedPhotos(List<List<LibraryPhoto>> lists) {
    final records = _filters.sort == 'rating' ? library.records : null;
    final same = _sortedFrom != null &&
        _sortedFrom!.length == lists.length &&
        [for (var i = 0; i < lists.length; i++) identical(_sortedFrom![i], lists[i])].every((s) => s) &&
        _sortedBy == _filters.sort &&
        identical(_sortedRecords, records);
    if (!same) {
      _sorted = sortedPhotos(lists, library.records, _filters.sort);
      _sortedFrom = lists;
      _sortedBy = _filters.sort;
      _sortedRecords = records;
    }
    return _sorted;
  }

  // ── Actions ───────────────────────────────────────────────────────────────────────────────

  Future<void> _addFolder({required bool negative}) async {
    final String? path;
    try {
      path = await chooseFolder();
    } catch (e) {
      library.showError(fileProblem(e));
      return;
    }
    if (path == null) return;
    final id = library.addFolder(path, negative: negative);
    if (id != null) _select((folderId: id, path: ''));
  }

  void _select(LibraryScope scope) => setState(() {
        _scope = scope;
        _selection = const LibrarySelection();
      });

  void _press(List<LibraryPhoto> photos, String key, {required bool range, required bool toggle}) =>
      setState(() {
        // A click on one of several chosen photos keeps them, so they can be dragged or opened.
        if (!(!range && !toggle && _selection.selected.contains(key) && _selection.selected.length > 1)) {
          _selection = nextSelection(photos, _selection, key, range: range, toggle: toggle);
        }
        _focusKey = key;
      });

  Future<void> _open(List<LibraryPhoto> list) async {
    if (list.isEmpty) return;
    await library.openPhotos(list, sort: _filters.sort, handoff: _origins[list.first.key]?.call());
  }

  void _rate(String key, int rating) => library
      .rate(_selection.selected.contains(key) ? _selection.selected : {key}, rating);

  Future<void> _rename(LibraryPhoto photo, String name) async {
    final renamed = await library.renamePhoto(photo, name);
    if (renamed == null || !mounted) return;
    String swap(String? key) => key == photo.key ? renamed : key!;
    setState(() {
      _selection = LibrarySelection(
          {for (final k in _selection.selected) swap(k)},
          _selection.anchor == null ? null : swap(_selection.anchor));
      if (_focusKey != null) _focusKey = swap(_focusKey);
    });
  }

  void _confirmTrash(List<LibraryPhoto> list) {
    if (list.isEmpty) return;
    showConfirmDialog(
      context,
      title: list.length == 1
          ? 'Move “${list.single.name}” to the Trash?'
          : 'Move ${list.length} photos to the Trash?',
      action: 'Move to Trash',
      onConfirm: () async {
        final removed = await library.trashPhotos(list);
        if (!mounted || removed.isEmpty) return;
        setState(() => _selection = LibrarySelection(
            {for (final k in _selection.selected) if (!removed.contains(k)) k},
            removed.contains(_selection.anchor) ? null : _selection.anchor));
      },
    );
  }

  void _confirmRemove(LibraryFolder folder) => showConfirmDialog(
        context,
        title: 'Remove “${folder.name}”?',
        body: 'Fotufilm forgets this folder with its ratings and saved edits. '
            'The files themselves are not changed.',
        action: 'Remove',
        onConfirm: () => library.removeFolder(folder.id),
      );

  void _menu(List<LibraryPhoto> photos, String key, Offset position) {
    setState(() => _focusKey = key);
    final targets = menuTargets(photos, _selection.selected, key);
    final single = targets.length == 1;
    showMenuAt(context, position, width: 200, [
      MenuItem(label: single ? 'Open' : 'Open ${targets.length} Photos', onSelected: () => _open(targets)),
      if (HostWindow.showsFiles) ...[
        MenuItem(label: HostWindow.revealLabel, onSelected: () => library.reveal(targets)),
        const MenuItem.divider(),
      ],
      MenuItem(
        label: _selection.selected.contains(key) ? 'Deselect' : 'Select',
        onSelected: () =>
            setState(() => _selection = nextSelection(photos, _selection, key, toggle: true)),
      ),
      if (HostWindow.showsFiles) ...[
        const MenuItem.divider(),
        if (single)
          MenuItem(
            label: 'Rename…',
            onSelected: () => showRenameDialog(context, targets.single.name, (name) => _rename(targets.single, name)),
          ),
        MenuItem(label: 'Move to Trash…', onSelected: () => _confirmTrash(targets)),
      ],
    ]);
  }

  // ── Keyboard ──────────────────────────────────────────────────────────────────────────────

  KeyEventResult _key(List<LibraryPhoto> photos, KeyEvent event, GridLayout layout, double viewport) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final command = keys.isMetaPressed || keys.isControlPressed;
    final key = event.logicalKey;
    final selected = [for (final p in photos) if (_selection.selected.contains(p.key)) p];
    final pageRows = (viewport / layout.row).floor().clamp(1, 1 << 20);
    final steps = {
      LogicalKeyboardKey.arrowLeft: -1,
      LogicalKeyboardKey.arrowRight: 1,
      LogicalKeyboardKey.arrowUp: -layout.columns,
      LogicalKeyboardKey.arrowDown: layout.columns,
      LogicalKeyboardKey.pageUp: -layout.columns * pageRows,
      LogicalKeyboardKey.pageDown: layout.columns * pageRows,
      LogicalKeyboardKey.home: -photos.length,
      LogicalKeyboardKey.end: photos.length,
    };
    final step = steps[key];
    if (step != null) {
      final next = steppedKey(photos, _focusKey, step);
      if (next != null) {
        setState(() {
          _focusKey = next;
          _selection = nextSelection(photos, _selection, next, range: keys.isShiftPressed);
        });
      }
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.keyA) {
      setState(() => _selection = LibrarySelection({for (final p in photos) p.key}, _focusKey));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _open(selected);
      return KeyEventResult.handled;
    }
    if (command && key == LogicalKeyboardKey.backspace && HostWindow.showsFiles) {
      _confirmTrash(selected);
      return KeyEventResult.handled;
    }
    final digit = event.character == null ? null : int.tryParse(event.character!);
    if (!command && digit != null && digit <= 5 && _selection.selected.isNotEmpty) {
      library.rate(_selection.selected, digit);
      return KeyEventResult.handled;
    }
    if (!command && key == LogicalKeyboardKey.keyL) {
      library.setOpen(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_selection.selected.isNotEmpty) {
        setState(() => _selection = const LibrarySelection());
      } else {
        library.setOpen(false);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── Layout ────────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final open = library.open;
    if (!_shown) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !open,
      child: ExcludeFocus(
        excluding: !open,
        child: AnimatedOpacity(
          opacity: open ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          curve: _ease,
          child: TickerMode(enabled: open, child: _content(context)),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final palette = Palette.of(context);
    final folders = library.folders;
    // A folder or subfolder that disappears, removed or emptied on a rescan, leaves its parent
    // in view.
    var folder = library.folderById(_scope.folderId);
    if (_scope.folderId != allFolders && folder == null) {
      _scope = (folderId: allFolders, path: '');
    } else if (folder != null && !folderTree(folder.photos).containsKey(_scope.path)) {
      _scope = (folderId: folder.id, path: '');
    }
    final scopeFolders = folder != null ? [folder] : folders;
    final subfolder = folder == null ? null : folderTree(folder.photos)[_scope.path];
    final sorted = _sortedPhotos([for (final f in scopeFolders) f.photos]);
    final photos = filteredPhotos(sorted, library.records,
        path: _scope.path,
        search: _filters.search,
        minRating: _filters.minRating,
        editedOnly: _filters.editedOnly);
    final total = folders.fold<int>(0, (sum, f) => sum + f.photos.length);
    final selected = [for (final p in photos) if (_selection.selected.contains(p.key)) p];
    final filtered = _filters.search.isNotEmpty || _filters.minRating > 0 || _filters.editedOnly;
    final scanning = scopeFolders.any((f) => f.status == 'scanning');

    return ColoredBox(
      color: palette.canvas,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: Metrics.filmWidth,
          child: LibraryFolders(
            folders: folders,
            scope: _scope,
            total: total,
            onSelect: _select,
            onAdd: _addFolder,
            onRescan: library.scan,
            onRemove: _confirmRemove,
            onMarkNegative: (f, negative) => library.markNegative(f.id, negative),
          ),
        ),
        Expanded(
          child: TweenAnimationBuilder<double>(
            // The grid settles into place as the library opens.
            tween: Tween(begin: 0, end: library.open ? 1 : 0),
            duration: const Duration(milliseconds: 260),
            curve: _ease,
            builder: (context, t, child) => Transform.translate(
              offset: Offset(0, 6 * (1 - t)),
              child: Transform.scale(scale: .992 + .008 * t, alignment: Alignment.topCenter, child: child),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LibraryBar(
                title: subfolder != null && subfolder.name.isNotEmpty
                    ? subfolder.name
                    : folder?.name ?? 'All Photos',
                shown: photos.length,
                selected: selected.length,
                filters: _filters,
                onFilters: (f) => setState(() => _filters = f),
                tileSize: _tileSize,
                onTileSize: (size) {
                  setState(() => _tileSize = size);
                  widget.editor.settings.set(_tileSizeKey, size);
                },
                onOpen: () => _open(selected),
              ),
              if (library.error != null) _Notice(text: library.error!, onDismiss: library.dismissError),
              Expanded(
                child: PhotoGrid(
                  photos: photos,
                  records: library.records,
                  tileSize: _tileSize,
                  thumbnails: library.thumbnails,
                  active: library.open,
                  selected: _selection.selected,
                  focusKey: _focusKey,
                  focusNode: _grid,
                  origins: _origins,
                  onPress: (key, {required range, required toggle}) =>
                      _press(photos, key, range: range, toggle: toggle),
                  onOpen: (key) => _open([for (final p in photos) if (p.key == key) p]),
                  onRate: _rate,
                  onMenu: (key, position) => _menu(photos, key, position),
                  onKey: (event, layout, viewport) => _key(photos, event, layout, viewport),
                  contentKey: '${_scope.folderId}/${_scope.path}',
                  empty: photos.isNotEmpty || scanning
                      ? null
                      : _Empty(
                          folders: scopeFolders.isNotEmpty,
                          filtered: filtered && total > 0,
                          onAdd: () => _addFolder(negative: false),
                          onClear: () => setState(() => _filters = (
                                search: '',
                                sort: _filters.sort,
                                minRating: 0,
                                editedOnly: false,
                              )),
                        ),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.folders, required this.filtered, required this.onAdd, required this.onClear});
  final bool folders, filtered;
  final VoidCallback onAdd, onClear;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final text = editorText(context, size: TextSizes.section, color: palette.muted);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (filtered) ...[
            Text('No photos match.', style: text),
            const SizedBox(height: 12),
            Row(mainAxisSize: MainAxisSize.min, children: [PillButton('Clear Filters', onPressed: onClear)]),
          ] else if (folders)
            Text('No photos in this folder.', style: text)
          else ...[
            AppIcon('library', size: 36, color: palette.muted),
            const SizedBox(height: 12),
            Text('Add a folder to browse, rate and open its photos.', style: text),
            const SizedBox(height: 12),
            Row(mainAxisSize: MainAxisSize.min, children: [
              PillButton('Add Folder', variant: ButtonVariant.accent, onPressed: onAdd),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// A problem with the library, over the grid until dismissed (`.library-notice`).
class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.onDismiss});
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dark = Palette.of(context).dark;
    final ink = dark ? const Color(0xFFF0C6B9) : const Color(0xFF7A3520);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF402D2A) : const Color(0xFFFFF4EF),
        border: Border.all(color: dark ? const Color(0xFF765045) : const Color(0xFFEFC2B3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        Expanded(child: Text(text, style: editorText(context, color: ink))),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: onDismiss,
          child: Text('Dismiss',
              style: editorText(context, color: ink).copyWith(decoration: TextDecoration.underline)),
        ),
      ]),
    );
  }
}
