// The editor's window: the toolbar over the film library, the viewer and the inspector, with the
// panels' resizers, dropped files, the commands and their menus, and the keyboard.
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../model/file_types.dart';
import '../model/film_packs.dart';
import '../model/panel_layout.dart';
import '../ui/inspector/inspector.dart';
import '../ui/kit/focus.dart' show KeyTarget, returnGoesPast;
import '../ui/kit/popover.dart' show OverlayFocusScope;
import '../ui/theme/theme.dart';
import '../ui/workspace/app_dialogs.dart';
import '../ui/workspace/editing_dialogs.dart';
import '../ui/workspace/export_dialog.dart';
import '../ui/workspace/film_library.dart';
import '../ui/workspace/library/library_handoff.dart';
import '../ui/workspace/library/photo_library_view.dart';
import '../ui/workspace/panel_layout.dart';
import '../ui/workspace/saved_export_notice.dart';
import '../ui/workspace/toolbar.dart';
import '../ui/workspace/video_controls.dart' show VideoKeys;
import '../ui/workspace/viewer.dart';
import 'commands.dart';
import 'editor_shortcuts.dart';
import 'host_window.dart';
import 'native_menu.dart';

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
  late final AppLifecycleListener _lifecycle;

  /// The commands, with what they open in this window.
  late final commands = EditorCommands(
    editor,
    CommandActions(
      open: _open,
      export: _export,
      copySettings: () => showCopySettingsDialog(context, editor),
      savePreset: () => showSavePresetDialog(context, editor),
      managePresets: () => showPresetsDialog(context, editor),
      importLooks: () => importLooks(context, editor),
    ),
  );
  late final _shortcuts = EditorShortcuts(commands);

  @override
  void initState() {
    super.initState();
    editor.addListener(_changed);
    editor.library.addListener(_libraryChanged);
    editor.layout.addListener(_changed);
    // The window put behind ends the comparison and a slider's drag.
    _lifecycle = AppLifecycleListener(onInactive: () {
      editor.setComparing(false);
      editor.endEdit();
    });
    FocusManager.instance.addListener(_keepKeys);
    // Return applies the crop whatever control the keyboard is at (editor_shortcuts.dart).
    returnGoesPast = () => editor.crop.showing;
  }

  /// Keys that would go nowhere (a dialog closed, a focused control gone) come back to the
  /// editor, as a page's keys reach its window whatever has the focus.
  void _keepKeys() {
    bool lost() => switch (FocusManager.instance.primaryFocus) {
          null => true,
          // An open popover or dialog holds them until it closes.
          OverlayFocusScope _ => false,
          // A scope holds the focus itself when nothing in it does.
          final FocusScopeNode _ => true,
          _ => false,
        };
    if (!lost()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && lost()) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    editor.removeListener(_changed);
    editor.library.removeListener(_libraryChanged);
    editor.layout.removeListener(_changed);
    _lifecycle.dispose();
    FocusManager.instance.removeListener(_keepKeys);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _nameWindow();
  }

  /// The window is named after the photo open in it; with none, after the app.
  String? _title;
  void _nameWindow() {
    final title = editor.active?.name ?? 'Fotufilm';
    if (title == _title) return;
    _title = title;
    HostWindow.setTitle(title);
  }

  /// The library shown or hidden; hidden, the keyboard comes back to the editor.
  bool _libraryOpen = false;
  void _libraryChanged() {
    final open = editor.library.open;
    if (_libraryOpen == open) return;
    setState(() => _libraryOpen = open);
    if (!open) _focus.requestFocus();
  }

  Future<void> _open() async {
    if (!editor.ready) return;
    final files = await openFiles(acceptedTypeGroups: [
      fileType('Images', imageExtensions),
      fileType('Videos', videoExtensions),
    ]);
    if (!kIsWeb && files.isNotEmpty) HostWindow.noteRecent([for (final f in files) f.path]);
    // One file brings its folder into the strip.
    await editor.strip.open([for (final f in files) _photo(f)]);
  }

  /// A chosen or dropped file: by path on the desktop, by its bytes in a browser.
  static PhotoFile _photo(XFile file) =>
      PhotoFile(file.name, path: kIsWeb ? null : file.path, read: file.readAsBytes);

  void _export() {
    if (editor.active != null) showExportDialog(context, editor);
  }

  /// A click outside the viewer gives the keys back to the editor.
  void _pointerDown(PointerDownEvent event) {
    final viewer = FocusManager.instance.primaryFocus?.context;
    if (viewer == null || viewer.findAncestorWidgetOfExactType<VideoKeys>() == null) return;
    final box = viewer.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    if (!(box.localToGlobal(Offset.zero) & box.size).contains(event.position)) {
      _focus.requestFocus();
    }
  }

  void _drop(DropDoneDetails detail) {
    setState(() => _dropping = false);
    // Film packs are installed; the rest open.
    final packs = [for (final f in detail.files) if (isFilmPack(f.name)) f.path];
    if (packs.isNotEmpty) editor.filmPacks.importPaths(packs);
    final photos = [
      for (final f in detail.files)
        if (imageExtensions.contains(f.name.split('.').last.toLowerCase()) || isVideoName(f.name)) f,
    ];
    // Dropped photographs join Open Recent too.
    if (!kIsWeb && photos.isNotEmpty) HostWindow.noteRecent([for (final f in photos) f.path]);
    editor.openFiles([for (final f in photos) _photo(f)]);
  }

  @override
  Widget build(BuildContext context) {
    return NativeMenuBar(
      commands: commands,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (node, event) => _shortcuts.handle(event),
        child: Listener(
          onPointerDown: _pointerDown,
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
                  child: Stack(children: [
                    Column(children: [
                      AppDialogHost(editor: editor),
                      EditorToolbar(commands: commands),
                      // The photo library covers the panels when it is shown.
                      Expanded(
                        child: Stack(children: [
                          Positioned.fill(child: LayoutBuilder(builder: _panels)),
                          Positioned.fill(child: PhotoLibraryView(editor: editor)),
                        ]),
                      ),
                    ]),
                    SavedExportNotice(editor: editor),
                    Positioned.fill(child: LibraryHandoffLayer(editor: editor)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The panels, the inspector giving way first and then the film library, so the picture keeps
  /// its minimum width.
  Widget _panels(BuildContext context, BoxConstraints constraints) {
    final total = constraints.maxWidth;
    final layout = editor.layout;
    // The window's width chooses the layout; the model hears of it after this frame.
    if (layout.window != total) {
      WidgetsBinding.instance.addPostFrameCallback((_) => layout.layOut(total));
    }
    if (total <= compactMaxWidth) return _compactPanels(context, constraints);
    final preferred = layout.preferred;
    var film = editor.filmOpen ? preferred.film : Metrics.filmCollapsed;
    var inspector = editor.inspectorOpen ? preferred.inspector : Metrics.railWidth;
    final excess = film + inspector + Metrics.pictureMin - total;
    if (excess > 0 && editor.inspectorOpen) {
      inspector = math.max(Metrics.inspectorMin, inspector - excess);
    }
    final still = film + inspector + Metrics.pictureMin - total;
    if (still > 0 && editor.filmOpen) film = math.max(Metrics.filmMin, film - still);
    // The resizers straddle the panels' edges, over the panels.
    const hit = Metrics.resizerHit;
    return Stack(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: film, child: FilmLibrary(editor: editor)),
        Expanded(child: EditorViewer(editor: editor, onOpen: _open, dropping: _dropping)),
        SizedBox(
          width: inspector,
          child: editor.inspectorOpen
              ? EditorInspector(editor: editor)
              : InspectorRail(editor: editor),
        ),
      ]),
      if (editor.filmOpen)
        Positioned(
          left: film - hit / 2,
          top: 0,
          bottom: 0,
          width: hit,
          child: _Resizer(
            label: 'Resize film list',
            onDrag: (dx) => layout.setWidth(PanelSide.film, layout.widths.film + dx),
            onEnd: layout.keepWidths,
            onReset: () => layout.setWidth(PanelSide.film, Metrics.filmWidth, keep: true),
          ),
        ),
      if (editor.inspectorOpen)
        Positioned(
          right: inspector - hit / 2,
          top: 0,
          bottom: 0,
          width: hit,
          child: _Resizer(
            label: 'Resize darkroom panel',
            onDrag: (dx) =>
                layout.setWidth(PanelSide.inspector, layout.widths.inspector - dx),
            onEnd: layout.keepWidths,
            onReset: () =>
                layout.setWidth(PanelSide.inspector, Metrics.inspectorWidth, keep: true),
          ),
        ),
    ]);
  }

  /// The phone's stacked layout: the picture, the film list's dock when it is open, and the
  /// inspector's dock over the rail of panels.
  Widget _compactPanels(BuildContext context, BoxConstraints constraints) {
    final height = MediaQuery.sizeOf(context).height;
    final short = height <= 500;
    final dock = short
        ? height * .42
        : (height * .44).clamp(Metrics.compactDockMin, Metrics.compactDockMax).toDouble();
    Widget sheet(Widget child) => DecoratedBox(
          decoration: const BoxDecoration(boxShadow: [
            BoxShadow(color: Color(0x09000000), blurRadius: 18, offset: Offset(0, -4)),
          ]),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: child,
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: EditorViewer(editor: editor, onOpen: _open, dropping: _dropping)),
      if (editor.filmOpen)
        SizedBox(
          height: short ? 138 : Metrics.compactFilmDock,
          child: sheet(FilmLibrary(editor: editor)),
        ),
      SizedBox(
        height: editor.inspectorOpen ? dock : Metrics.compactRail,
        child: editor.inspectorOpen
            ? sheet(EditorInspector(editor: editor))
            : CompactRail(editor: editor),
      ),
    ]);
  }
}

/// The strip on a panel's edge that resizes it, with the accent line while hovered.
class _Resizer extends StatefulWidget {
  const _Resizer(
      {required this.label, required this.onDrag, required this.onEnd, required this.onReset});
  final String label;
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd, onReset;

  @override
  State<_Resizer> createState() => _ResizerState();
}

class _ResizerState extends State<_Resizer> {
  bool _active = false;

  @override
  // The arrow keys move the edge 16 points, 64 with Shift.
  Widget build(BuildContext context) => KeyTarget(
        label: widget.label,
        onNudge: (direction, shift) {
          widget.onDrag(direction.dx * (shift ? 64 : 16));
          widget.onEnd();
        },
        radius: 1,
        child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _active = true),
        onExit: (_) => setState(() => _active = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
          onHorizontalDragEnd: (_) => widget.onEnd(),
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
      );
}
