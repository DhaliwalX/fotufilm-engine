// The library's folders: All Photos, each folder with its count or its state, and its subfolders
// under a disclosure. A folder's menu rescans it, opens it as negatives or photos, or removes it
// from the library.
import 'package:flutter/widgets.dart';

import '../../../model/editor.dart';
import '../../../model/library_model.dart';
import '../../kit/kit.dart';
import '../../theme/theme.dart';
import 'photo_grid.dart' show libraryHover;

/// What the grid shows: all photos, a folder, or one of its subfolders.
typedef LibraryScope = ({String folderId, String path});

const allFolders = 'all';

class LibraryFolders extends StatefulWidget {
  const LibraryFolders({
    super.key,
    required this.folders,
    required this.scope,
    required this.total,
    required this.onSelect,
    required this.onAdd,
    required this.onRescan,
    required this.onRemove,
    required this.onMarkNegative,
  });

  final List<LibraryFolder> folders;
  final LibraryScope scope;
  final int total;
  final ValueChanged<LibraryScope> onSelect;
  final void Function({required bool negative}) onAdd;
  final ValueChanged<LibraryFolder> onRescan, onRemove;
  final void Function(LibraryFolder folder, bool negative) onMarkNegative;

  @override
  State<LibraryFolders> createState() => _LibraryFoldersState();
}

class _LibraryFoldersState extends State<LibraryFolders> {
  final _expanded = <String>{};
  final _scroll = ScrollController();

  static String _node(String folderId, String path) => '$folderId/$path';

  @override
  void didUpdateWidget(LibraryFolders old) {
    super.didUpdateWidget(old);
    // The chosen folder opens to show what is inside it.
    _expanded.add(_node(widget.scope.folderId, widget.scope.path));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggle(String id) => setState(() => _expanded.contains(id) ? _expanded.remove(id) : _expanded.add(id));

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final trees = [for (final f in widget.folders) folderTree(f.photos)];
    final nested = trees.any((t) => t['']!.children.isNotEmpty);
    final scope = widget.scope;
    final rows = <Widget>[
      _FolderRow(
        icon: 'library',
        name: 'All Photos',
        trailing: _Count(widget.total),
        current: scope.folderId == allFolders,
        nested: nested,
        onTap: () => widget.onSelect((folderId: allFolders, path: '')),
      ),
    ];
    for (final (index, folder) in widget.folders.indexed) {
      final root = trees[index][''];
      final id = _node(folder.id, '');
      final open = _expanded.contains(id);
      rows.add(_FolderRow(
        icon: 'folder',
        name: folder.name,
        tooltip: [folder.path, if (folder.negative) 'scanned negatives'].join(' · '),
        trailing: _FolderStatus(folder),
        current: scope.folderId == folder.id && scope.path.isEmpty,
        nested: nested,
        expanded: root!.children.isEmpty ? null : open,
        onToggle: () => _toggle(id),
        onTap: () => widget.onSelect((folderId: folder.id, path: '')),
        menu: [
          MenuItem(label: 'Rescan', onSelected: () => widget.onRescan(folder)),
          MenuItem(
            label: folder.negative ? 'Open as Photos' : 'Open as Negatives',
            onSelected: () => widget.onMarkNegative(folder, !folder.negative),
          ),
          MenuItem(label: 'Remove from Library…', onSelected: () => widget.onRemove(folder)),
        ],
      ));
      if (open) _subfolders(rows, folder, root, 1, nested);
    }
    return ColoredBox(
      color: palette.panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 39,
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(children: [
            Expanded(
              child: Text('Library',
                  style: editorText(context, size: TextSizes.body, weight: FontWeight.w700)),
            ),
            // A folder of scanned negatives is added as one.
            Builder(
              builder: (anchor) => QuietButton(
                icon: 'addFolder',
                tooltip: 'Add Folder',
                opensMenu: true,
                onPressed: () => showMenu(anchor, alignEnd: true, width: 210, [
                  MenuItem(label: 'Add Folder…', onSelected: () => widget.onAdd(negative: false)),
                  MenuItem(
                      label: 'Add Negatives Folder…', onSelected: () => widget.onAdd(negative: true)),
                ]),
              ),
            ),
          ]),
        ),
        Expanded(
          child: ThinScroll(
            controller: _scroll,
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: rows,
            ),
          ),
        ),
      ]),
    );
  }

  /// A folder's open subfolders, depth first, as flat rows.
  void _subfolders(List<Widget> rows, LibraryFolder folder, FolderNode node, int depth, bool nested) {
    for (final child in node.children) {
      final id = _node(folder.id, child.path);
      final open = _expanded.contains(id);
      rows.add(_FolderRow(
        icon: 'folder',
        name: child.name,
        tooltip: '${folder.name}/${child.path}',
        trailing: _Count(child.count),
        current: widget.scope.folderId == folder.id && widget.scope.path == child.path,
        nested: nested,
        depth: depth,
        expanded: child.children.isEmpty ? null : open,
        onToggle: () => _toggle(id),
        onTap: () => widget.onSelect((folderId: folder.id, path: child.path)),
      ));
      if (open) _subfolders(rows, folder, child, depth + 1, nested);
    }
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    required this.icon,
    required this.name,
    required this.trailing,
    required this.current,
    required this.nested,
    required this.onTap,
    this.tooltip,
    this.depth = 0,
    this.expanded,
    this.onToggle,
    this.menu,
  });

  final String icon, name;
  final String? tooltip;
  final Widget trailing;
  final bool current, nested;
  final int depth;

  /// Whether its subfolders show; null without subfolders.
  final bool? expanded;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  final List<MenuItem>? menu;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final indent = widget.depth * 14.0;
    // With subfolders, every row leaves room for the disclosure so the icons line up.
    final left = widget.nested ? 30 + indent : 10.0;
    final row = KeyTarget(
      onActivate: widget.onTap,
      label: widget.name,
      selected: widget.current,
      expanded: widget.expanded,
      radius: 6,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 34,
        padding: EdgeInsets.only(left: left, right: 10),
        decoration: BoxDecoration(
          color: widget.current
              ? palette.selected
              : _hovered
                  ? libraryHover(palette)
                  : const Color(0x00000000),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          AppIcon(widget.icon, size: 18, color: palette.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(widget.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: editorText(context)),
          ),
          // The count gives way to the folder's menu on hover.
          AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _hovered && widget.menu != null ? 0 : 1,
            child: widget.trailing,
          ),
        ]),
      ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(children: [
        widget.tooltip == null ? row : HoverTip(message: widget.tooltip, child: row),
        if (widget.expanded != null)
          Positioned(
            left: 6 + indent,
            top: 7,
            child: KeyTarget(
              onActivate: widget.onToggle,
              label: widget.expanded! ? 'Hide subfolders' : 'Show subfolders',
              child: GestureDetector(
              onTap: widget.onToggle,
              child: AnimatedRotation(
                turns: widget.expanded! ? .25 : 0,
                duration: const Duration(milliseconds: 160),
                curve: const Cubic(.2, .8, .2, 1),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: Center(child: AppIcon('chevronRight', size: 16, color: palette.muted)),
                ),
              ),
            ),
            ),
          ),
        if (widget.menu != null && _hovered)
          Positioned(
            right: 4,
            top: 7,
            child: Builder(
              builder: (anchor) => QuietButton(
                icon: 'more',
                size: 20,
                iconSize: 16,
                tooltip: '${widget.name} options',
                opensMenu: true,
                onPressed: () => showMenu(anchor, alignEnd: true, width: 200, widget.menu!),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Text(formatCount(count),
      style: editorText(context, size: TextSizes.label, color: Palette.of(context).muted));
}

/// A folder's count, with a spinner while it is read, or a warning when it cannot be.
class _FolderStatus extends StatelessWidget {
  const _FolderStatus(this.folder);
  final LibraryFolder folder;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    if (folder.status == 'error') {
      return HoverTip(
        message: folder.error,
        child: const AppIcon('warning', size: 14, color: Color(0xFFC2410C)),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (folder.status == 'scanning') ...[
        Spinner(color: palette.muted),
        const SizedBox(width: 6),
      ],
      _Count(folder.photos.length),
    ]);
  }
}

/// 1,234: counts with a thousands separator, as Intl.NumberFormat writes them.
String formatCount(int count) =>
    count.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Spectrum's small indeterminate progress circle.
class Spinner extends StatefulWidget {
  const Spinner({super.key, required this.color, this.size = 12});
  final Color color;
  final double size;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: _turn,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _Arc(widget.color),
        ),
      );
}

class _Arc extends CustomPainter {
  _Arc(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Offset.zero & size, 0, 4.2, false, paint);
  }

  @override
  bool shouldRepaint(_Arc old) => old.color != color;
}
