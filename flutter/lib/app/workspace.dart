// The editor's window: the toolbar over the film library, the viewer and the inspector, with the
// panels' resizers, dropped files, Space to compare and the commands.
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../ui/inspector/inspector.dart';
import '../ui/theme/theme.dart';
import '../ui/workspace/dialogs.dart';
import '../ui/workspace/film_library.dart';
import '../ui/workspace/toolbar.dart';
import '../ui/workspace/viewer.dart';
import 'commands.dart';

const imageExtensions = [
  'jpg', 'jpeg', 'png', 'tif', 'tiff', 'heic', 'heif', 'avif', 'exr', 'webp', //
  'dng', 'cr2', 'cr3', 'nef', 'nrw', 'arw', 'raf', 'orf', 'rw2', 'pef', 'srw', '3fr', 'iiq',
];

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  EditorModel get editor => widget.editor;
  final _focus = FocusNode(debugLabel: 'workspace');
  bool _dropping = false;
  double _filmWidth = Metrics.filmWidth, _inspectorWidth = Metrics.inspectorWidth;

  @override
  void initState() {
    super.initState();
    editor.addListener(_changed);
  }

  @override
  void dispose() {
    editor.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _open() async {
    if (!editor.ready) return;
    final files = await openFiles(acceptedTypeGroups: const [
      XTypeGroup(label: 'Images', extensions: imageExtensions),
    ]);
    await editor.openPaths([for (final f in files) f.path]);
  }

  void _export() {
    if (editor.active != null) showExportDialog(context, editor);
  }

  /// Holding Space shows the original, as in the web editor.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) return KeyEventResult.ignored;
    if (event is KeyDownEvent) editor.setComparing(true);
    if (event is KeyUpEvent) editor.setComparing(false);
    return KeyEventResult.handled;
  }

  void _drop(DropDoneDetails detail) {
    setState(() => _dropping = false);
    editor.openPaths([
      for (final f in detail.files)
        if (imageExtensions.contains(f.path.split('.').last.toLowerCase())) f.path,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final menus = editorCommands(editor, open: _open, export: _export);
    return CommandHost(
      menus: menus,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dropping = true),
          onDragExited: (_) => setState(() => _dropping = false),
          onDragDone: _drop,
          child: Material(
            type: MaterialType.transparency,
            child: DefaultTextStyle(
              style: editorText(context),
              child: ColoredBox(
                color: Palette.of(context).page,
                child: Column(children: [
                  EditorToolbar(
                    editor: editor,
                    onOpen: _open,
                    onExport: _export,
                    onShortcuts: () => showShortcutsDialog(context, shortcutRows(menus)),
                  ),
                  Expanded(child: LayoutBuilder(builder: _panels)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The panels, the inspector giving way first and then the film library, so the picture keeps
  /// its minimum width (web/src/editor/usePanelWidths.js).
  Widget _panels(BuildContext context, BoxConstraints constraints) {
    final total = constraints.maxWidth;
    var film = editor.filmOpen ? _filmWidth : Metrics.filmCollapsed;
    var inspector = editor.inspectorOpen ? _inspectorWidth : Metrics.railWidth;
    final excess = film + inspector + Metrics.pictureMin - total;
    if (excess > 0 && editor.inspectorOpen) {
      inspector = math.max(Metrics.inspectorMin, inspector - excess);
    }
    final still = film + inspector + Metrics.pictureMin - total;
    if (still > 0 && editor.filmOpen) film = math.max(Metrics.filmMin, film - still);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: film, child: FilmLibrary(editor: editor)),
      if (editor.filmOpen)
        _Resizer(
          onDrag: (dx) => setState(() =>
              _filmWidth = (_filmWidth + dx).clamp(Metrics.filmMin, Metrics.filmMax)),
          onReset: () => setState(() => _filmWidth = Metrics.filmWidth),
        ),
      Expanded(child: EditorViewer(editor: editor, onOpen: _open, dropping: _dropping)),
      if (editor.inspectorOpen)
        _Resizer(
          onDrag: (dx) => setState(() => _inspectorWidth =
              (_inspectorWidth - dx).clamp(Metrics.inspectorMin, Metrics.inspectorMax)),
          onReset: () => setState(() => _inspectorWidth = Metrics.inspectorWidth),
        ),
      SizedBox(
        width: inspector,
        child: editor.inspectorOpen
            ? EditorInspector(editor: editor)
            : InspectorRail(editor: editor),
      ),
    ]);
  }
}

/// The strip on a panel's edge that resizes it, with the accent line while hovered.
class _Resizer extends StatefulWidget {
  const _Resizer({required this.onDrag, required this.onReset});
  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  State<_Resizer> createState() => _ResizerState();
}

class _ResizerState extends State<_Resizer> {
  bool _active = false;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 0,
        child: OverflowBox(
          maxWidth: Metrics.resizerHit,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            onEnter: (_) => setState(() => _active = true),
            onExit: (_) => setState(() => _active = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
              onDoubleTap: widget.onReset,
              child: Center(
                child: Container(
                  width: 2,
                  decoration: BoxDecoration(
                    color: _active ? Palette.of(context).accent : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
