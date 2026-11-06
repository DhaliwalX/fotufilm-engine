// The editor on a phone: a top bar with Add, Undo and Redo while there is something to undo,
// More and Export; the picture; a docked sheet of the open group's pages; and the bar of groups
// along the bottom.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../app/commands.dart';
import '../../app/editor_shortcuts.dart' show shortcutLabel;
import '../../model/editor.dart';
import '../../model/library_files.dart' show libraryFilesAvailable;
import '../../model/phone_decks.dart';
import '../inspector/controls.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import '../workspace/export_progress.dart';
import '../workspace/import_menu.dart';
import '../workspace/toolbar.dart' show moreOptionsKey, showMoreOptions;
import '../workspace/viewer.dart';
import 'deck_pages.dart';

class PhoneEditor extends StatefulWidget {
  const PhoneEditor({super.key, required this.commands, required this.dropping});
  final EditorCommands commands;
  final bool dropping;

  @override
  State<PhoneEditor> createState() => _PhoneEditorState();
}

class _PhoneEditorState extends State<PhoneEditor> {
  EditorModel get editor => widget.commands.editor;
  PhoneDecks get decks => editor.layout.decks;

  /// The sheet's height as its grabber last left it.
  double _sheet = PhoneMetrics.sheet;

  /// The height the sheet had when its grabber was taken hold of.
  double? _held;

  @override
  void initState() {
    super.initState();
    decks.addListener(_changed);
  }

  @override
  void dispose() {
    decks.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final viewer = EditorViewer(
        editor: editor, onOpen: widget.commands.actions.open, dropping: widget.dropping);
    final deck = decks.open;
    return PhoneStyle(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: insets.top),
        _TopBar(commands: widget.commands),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            if (deck == null) return viewer;
            // A phone held sideways has the sheet beside the picture, the full height.
            if (editor.layout.side) {
              final width = (constraints.maxWidth * .45)
                  .clamp(Metrics.compactSideMin, Metrics.compactSideMax)
                  .toDouble();
              return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: viewer),
                SizedBox(width: width, child: _Sheet(decks: decks, deck: deck)),
              ]);
            }
            // The picture keeps its room above the tallest sheet.
            final tallest = math.max(
                PhoneMetrics.sheetMin, constraints.maxHeight - Metrics.compactPictureMin);
            final height = _sheet.clamp(PhoneMetrics.sheetMin * .5, tallest).toDouble();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: viewer),
              SizedBox(
                height: height,
                child: _Sheet(
                  decks: decks,
                  deck: deck,
                  onDrag: (dy) => setState(() {
                    _held ??= height;
                    _sheet = (height - dy).clamp(PhoneMetrics.sheetMin * .5, tallest).toDouble();
                  }),
                  onRelease: (velocity) => _release(velocity, tallest),
                ),
              ),
            ]);
          }),
        ),
        _DeckBar(decks: decks, bottom: insets.bottom),
      ]),
    );
  }

  /// The grabber let go: pulled well below the least height, or flung down, the sheet closes and
  /// comes back at the height it had; flung up, it takes all the room it may.
  void _release(double velocity, double tallest) {
    final before = _held ?? _sheet;
    _held = null;
    if (velocity > 700 || _sheet < PhoneMetrics.sheetMin * .75) {
      setState(() => _sheet = before);
      decks.show(null);
    } else if (velocity < -700) {
      setState(() => _sheet = tallest);
    } else if (_sheet < PhoneMetrics.sheetMin) {
      setState(() => _sheet = PhoneMetrics.sheetMin);
    }
  }
}

/// Add media, Undo and Redo, More and Export.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.commands});
  final EditorCommands commands;

  EditorModel get editor => commands.editor;

  @override
  Widget build(BuildContext context) {
    final doc = editor.active;
    final exporting = editor.exporting;
    return SizedBox(
      height: PhoneMetrics.topBar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Builder(
            builder: (anchor) => RoundButton(
              glyph: 'fotu.ui.add',
              label: 'Add media',
              onPressed: exporting
                  ? null
                  : () => showImportMenu(anchor, editor, commands.actions.open),
            ),
          ),
          // A browser reads no folders, so it has no library.
          if (libraryFilesAvailable) ...[
            const SizedBox(width: 6),
            RoundButton(
              glyph: 'fotu.ui.photos',
              label: 'Library',
              onPressed: exporting ? null : editor.library.toggle,
            ),
          ],
          _History(editor: editor),
          const Spacer(),
          if (editor.exporter.busy) ...[
            ExportProgressButton(editor: editor, size: PhoneMetrics.roundButton),
            const SizedBox(width: 6),
          ],
          Builder(
            key: moreOptionsKey,
            builder: (anchor) => RoundButton(
              glyph: 'fotu.ui.more',
              label: 'More options',
              opensMenu: true,
              onPressed: () => showMoreOptions(anchor, commands),
            ),
          ),
          const SizedBox(width: 6),
          RoundButton(
            glyph: 'fotu.ui.share',
            label: 'Export (${shortcutLabel('⌘E')})',
            onPressed: doc != null && editor.stocks.isNotEmpty && !exporting
                ? commands.actions.export
                : null,
          ),
        ]),
      ),
    );
  }
}

/// Undo and Redo, while either has something to do.
class _History extends StatelessWidget {
  const _History({required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final history = editor.active?.history;
    final undo = (history?.past.isNotEmpty ?? false) && !editor.exporting;
    final redo = (history?.future.isNotEmpty ?? false) && !editor.exporting;
    if (!undo && !redo) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(width: 6),
      RoundButton(
        glyph: 'fotu.ui.undo',
        label: editor.history.undo,
        onPressed: undo ? editor.undo : null,
      ),
      const SizedBox(width: 6),
      RoundButton(
        glyph: 'fotu.ui.redo',
        label: editor.history.redo,
        onPressed: redo ? editor.redo : null,
      ),
    ]);
  }
}

/// The open group's pages: the grabber, the pages' tabs, and the page.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.decks, required this.deck, this.onDrag, this.onRelease});
  final PhoneDecks decks;
  final PhoneDeck deck;

  /// The grabber's drag; a sheet beside the picture has none.
  final ValueChanged<double>? onDrag;
  final ValueChanged<double>? onRelease;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final editor = decks.editor;
    final page = decks.page!;
    final children = deckPage(page, InspectorControls(editor));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.border, width: .5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          button: true,
          label: 'Close ${deck.title}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: onDrag == null ? null : (d) => onDrag!(d.delta.dy),
            onVerticalDragEnd:
                onRelease == null ? null : (d) => onRelease!(d.velocity.pixelsPerSecond.dy),
            onTap: () => decks.show(null),
            child: SizedBox(
              height: PhoneMetrics.grabber,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x4DFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
        _Tabs(decks: decks, deck: deck, page: page),
        Expanded(
          child: SingleChildScrollView(
            key: PageStorageKey(page),
            padding: PhoneMetrics.sheetPadding,
            // The controls wait for a photograph.
            child: AbsorbPointer(
              absorbing: editor.active == null || editor.exporting,
              child: FlatSections(
                flat: flatPage(page),
                child: Column(
                  // A new page or film is a new set of controls, not the old ones updated.
                  key: ValueKey('$page:${editor.edit['stock']}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const SizedBox(height: PhoneMetrics.controlGap),
                      children[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The open group's pages, each its glyph and its name in caps, the chosen one underlined in
/// the accent. A tool has Done at the end.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.decks, required this.deck, required this.page});
  final PhoneDecks decks;
  final PhoneDeck deck;
  final DeckPage page;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final pages = decks.pages(deck);
    return Container(
      height: PhoneMetrics.tabs,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border, width: .5)),
      ),
      child: Row(children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final p in pages)
                _Tab(page: p, selected: p == page, onPressed: () => decks.choosePage(p)),
            ],
          ),
        ),
        if (deck.tool != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => decks.show(null),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: Text('Done',
                    style: editorText(context,
                        size: TextSizes.section, weight: FontWeight.w700, color: palette.accent)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.page, required this.selected, required this.onPressed});
  final DeckPage page;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final fg = selected ? palette.text : palette.text.withValues(alpha: .5);
    return Semantics(
      button: true,
      selected: selected,
      label: page.title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: selected ? palette.accent : const Color(0x00000000), width: 2),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Glyph(page.glyph, size: PhoneMetrics.tabIcon, color: fg),
            const SizedBox(width: 5),
            Text(page.title.toUpperCase(), style: capsText(context, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// The groups along the bottom, each its glyph over its name; the open one in the accent. They
/// scroll sideways when there are more than fit.
class _DeckBar extends StatelessWidget {
  const _DeckBar({required this.decks, required this.bottom});
  final PhoneDecks decks;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final editor = decks.editor;
    final all = decks.decks;
    final enabled = editor.active != null && !editor.exporting;
    Widget button(PhoneDeck d) => _DeckButton(
          deck: d,
          selected: decks.open == d,
          onPressed: enabled ? () => decks.pressed(d) : null,
        );
    return Container(
      height: PhoneMetrics.deckBar + bottom,
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        border: Border(top: BorderSide(color: palette.border, width: .5)),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        if (all.length * PhoneMetrics.deckButton <= constraints.maxWidth) {
          return Row(children: [for (final d in all) Expanded(child: button(d))]);
        }
        return ListView(
          scrollDirection: Axis.horizontal,
          itemExtent: PhoneMetrics.deckButton,
          children: [for (final d in all) button(d)],
        );
      }),
    );
  }
}

class _DeckButton extends StatelessWidget {
  const _DeckButton({required this.deck, required this.selected, required this.onPressed});
  final PhoneDeck deck;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final fg = onPressed == null
        ? palette.text.withValues(alpha: .3)
        : selected
            ? palette.accent
            : palette.text;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onPressed != null,
      label: deck.title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 34,
            height: 26,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF333333) : null,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Glyph(deck.glyph, size: PhoneMetrics.deckIcon, color: fg),
          ),
          const SizedBox(height: 3),
          Text(deck.title,
              maxLines: 1,
              overflow: TextOverflow.visible,
              softWrap: false,
              style: editorText(context, size: 9, weight: FontWeight.w500, color: fg)),
        ]),
      ),
    );
  }
}

/// The phone's round button: a dark disc with a glyph.
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onPressed,
    this.size = PhoneMetrics.roundButton,
    this.opensMenu = false,
  });

  final String glyph, label;
  final VoidCallback? onPressed;
  final double size;

  /// It opens a menu, so it acts as the press starts.
  final bool opensMenu;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: opensMenu && enabled ? (_) => onPressed!() : null,
        onTap: opensMenu ? null : onPressed,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFF202020),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x1FFFFFFF), width: .5),
          ),
          alignment: Alignment.center,
          child: Glyph(glyph,
              size: size * .5,
              color: enabled ? palette.text : palette.text.withValues(alpha: .3)),
        ),
      ),
    );
  }
}
