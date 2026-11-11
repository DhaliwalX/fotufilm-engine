// The gallery on a phone, where the app opens: the brand over a grid of what is kept in Fotufilm,
// each a square of its developed picture, the most recently edited first. Scanned negatives are
// listed apart from photographs once there are both, and can be filed in rolls: a roll is a stack
// of its frames that opens to show them. A tile opens in the editor, its picture flying to the
// viewer; a long press offers what else can be done with it. The bar above has Open and Settings.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app/commands.dart';
import '../../model/app_dialogs.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import '../workspace/import_menu.dart';
import '../workspace/overlays.dart';
import '../workspace/picture.dart';
import '../workspace/startup_progress.dart';
import 'gallery_dialogs.dart';
import 'phone_editor.dart' show RoundButton;

/// The gallery's warm white: the brand and the headings.
const _warm = Color(0xFFFFF0F0);

abstract final class _Sizes {
  /// The grid's margin at the sides, the gap between tiles, and the room under the last row.
  static const side = 12.0, gap = 2.0, bottom = 20.0;

  /// The row over the grid.
  static const heading = 30.0;

  /// A roll's name and its date under its stack.
  static const rollLabels = 26.0;
}

class PhoneGallery extends StatefulWidget {
  const PhoneGallery({super.key, required this.commands});
  final EditorCommands commands;

  @override
  State<PhoneGallery> createState() => _PhoneGalleryState();
}

class _PhoneGalleryState extends State<PhoneGallery> {
  EditorCommands get commands => widget.commands;
  EditorModel get editor => commands.editor;
  Gallery get gallery => editor.gallery;

  /// Whether the engine was still starting when the gallery came up: its progress shows here
  /// the once, not each time the editor is left.
  late final _starting = !editor.startup.value.done;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    return PhoneStyle(
      child: ColoredBox(
        color: Palette.of(context).page,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: insets.top),
          _TopBar(commands: commands),
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _shelf(context, constraints.maxWidth, insets.bottom)),
              ),
              if (editor.status != null)
                StatusPill(
                    text: editor.status!, onCancel: editor.importing ? editor.cancelImport : null),
              if (editor.error != null)
                ErrorBanner(
                  text: editor.error!,
                  onClose: editor.dismissError,
                  onRetry: editor.canRetry ? editor.retry : null,
                ),
              if (_starting)
                StartupProgress(
                    key: const ValueKey('startup'), progress: editor.startup, compact: true),
            ]),
          ),
        ]),
      ),
    );
  }

  /// What the grid lists: an open roll's frames, a tab's side of the gallery, or all of it.
  List<Object> get _listed {
    final roll = gallery.rollOpen;
    if (roll != null) return gallery.framesOf(roll);
    if (gallery.tabbed && gallery.tab == GalleryTab.photos) return gallery.photos;
    return [
      ...gallery.rolls,
      if (gallery.tabbed)
        ...gallery.looseScans
      else
        for (final entry in gallery.entries)
          if (entry.roll == null) entry,
    ];
  }

  Widget _shelf(BuildContext context, double width, double bottom) {
    // With nothing kept there is only the brand.
    if (gallery.entries.isEmpty && gallery.rolls.isEmpty) return const Center(child: _Brand());
    final roll = gallery.rollOpen;
    final listed = _listed;
    return CustomScrollView(
      // The gallery comes back where it was left; a roll has its own place.
      key: PageStorageKey(roll == null ? 'gallery' : 'roll ${roll.id}'),
      slivers: [
        // Inside a roll the brand gives way and the frames rise to the bar.
        if (roll == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 16, bottom: 14),
              child: Center(child: _Brand()),
            ),
          ),
        SliverToBoxAdapter(child: _Heading(editor: editor)),
        SliverPadding(
          padding:
              EdgeInsets.fromLTRB(_Sizes.side, 0, _Sizes.side, _Sizes.bottom + bottom),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              // A wide screen takes five across.
              crossAxisCount: width > 480 ? 5 : 3,
              mainAxisSpacing: _Sizes.gap,
              crossAxisSpacing: _Sizes.gap,
            ),
            itemCount: listed.length,
            itemBuilder: (context, index) => switch (listed[index]) {
              final GalleryRoll roll =>
                _RollTile(key: ValueKey('roll ${roll.id}'), editor: editor, roll: roll),
              final GalleryEntry entry =>
                _EntryTile(key: ValueKey(entry.id), editor: editor, entry: entry),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
      ],
    );
  }
}

/// Back while a roll is open, then Open and Settings.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.commands});
  final EditorCommands commands;

  @override
  Widget build(BuildContext context) {
    final editor = commands.editor, gallery = editor.gallery;
    final roll = gallery.rollOpen;
    return SizedBox(
      height: PhoneMetrics.topBar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          if (roll != null) _BackPill(onPressed: () => gallery.showRoll(null)),
          const Spacer(),
          Builder(
            builder: (anchor) => RoundButton(
              glyph: 'fotu.ui.add',
              label: 'Open',
              onPressed: editor.exporting || gallery.closing
                  ? null
                  // Scans chosen inside a roll are filed in it.
                  : () => showMenu(anchor, alignEnd: true, width: 200, [
                        ...importMenuItems(editor, commands.actions.open, roll: roll),
                        const MenuItem.divider(),
                        MenuItem(
                            label: 'New Roll…', onSelected: () => showRollDialog(anchor, gallery)),
                      ]),
            ),
          ),
          const SizedBox(width: 6),
          RoundButton(
            glyph: 'fotu.ui.settings',
            label: 'Settings',
            onPressed: () => editor.dialogs.request(AppDialog.settings),
          ),
        ]),
      ),
    );
  }
}

/// The way back out of a roll.
class _BackPill extends StatelessWidget {
  const _BackPill({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Back',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: Container(
            height: PhoneMetrics.roundButton,
            padding: const EdgeInsets.only(left: 8, right: 13),
            decoration: BoxDecoration(
              color: const Color(0xFF202020),
              borderRadius: BorderRadius.circular(PhoneMetrics.roundButton / 2),
              border: Border.all(color: const Color(0x1FFFFFFF), width: .5),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const AppIcon('chevronLeft', size: 14),
              const SizedBox(width: 3),
              Text('Back',
                  style: editorText(context, size: TextSizes.section, weight: FontWeight.w500)),
            ]),
          ),
        ),
      );
}

/// The wordmark over what the app is for.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
          label: 'Fotufilm',
          child: SvgPicture.asset(
            'assets/generated/fotufilm-wordmark.svg',
            width: 150,
            height: 30,
            colorFilter: const ColorFilter.mode(_warm, BlendMode.srcIn),
          ),
        ),
        const SizedBox(height: 6),
        Text('film simulation & negatives',
            style: editorText(context, size: 10.5, color: const Color(0x99FFE8E8))),
      ]);
}

/// The row over the grid: Recent, the tabs once the gallery holds photographs and negatives
/// both, or the open roll's name, date and count beside its menu.
class _Heading extends StatelessWidget {
  const _Heading({required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final gallery = editor.gallery;
    final roll = gallery.rollOpen;
    final title = editorText(context, size: 13.5, weight: FontWeight.w600, color: _warm);
    final Widget row;
    if (roll != null) {
      final frames = gallery.framesOf(roll).length;
      row = Row(children: [
        Expanded(
          child: Semantics(
            label: '${roll.name}, ${dayText(roll.day)}, ${framesText(frames)}',
            excludeSemantics: true,
            child: Text.rich(
              TextSpan(text: roll.name, children: [
                TextSpan(
                    text: '  ${dayText(roll.day)} · $frames',
                    style: editorText(context,
                        size: 10.5, color: Palette.of(context).muted)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: title,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Builder(
          builder: (anchor) => RoundButton(
            glyph: 'fotu.ui.more',
            label: 'Roll',
            size: 27,
            opensMenu: true,
            onPressed: () =>
                showMenu(anchor, alignEnd: true, width: 200, rollMenu(anchor, editor, roll)),
          ),
        ),
      ]);
    } else if (gallery.tabbed) {
      row = SegmentedControl<GalleryTab>(
        items: const [(GalleryTab.photos, 'Photos'), (GalleryTab.negatives, 'Negatives')],
        selected: gallery.tab,
        onChanged: (tab) => gallery.tab = tab,
      );
    } else {
      row = Align(alignment: Alignment.centerLeft, child: Text('Recent', style: title));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(_Sizes.side, 0, _Sizes.side, 6),
      child: SizedBox(height: _Sizes.heading, child: row),
    );
  }
}

/// What a roll offers: more frames, its name and date, and deleting it.
List<MenuItem> rollMenu(BuildContext context, EditorModel editor, GalleryRoll roll) {
  final gallery = editor.gallery;
  final scans = scanMenuItems(editor, roll: roll);
  return [
    // One kind of scan to choose needs no menu of its own.
    if (scans.length == 1)
      MenuItem(label: 'Add Frames', onSelected: scans.single.onSelected)
    else
      MenuItem(label: 'Add Frames', submenu: scans),
    MenuItem(
        label: 'Rename and Date…', onSelected: () => showRollDialog(context, gallery, roll: roll)),
    MenuItem(label: 'Delete Roll…', onSelected: () => confirmDeleteRoll(context, gallery, roll)),
  ];
}

/// A photograph, a movie or a scan: its developed picture filling a square, with a badge on a
/// movie and on a scan.
class _EntryTile extends StatelessWidget {
  const _EntryTile({super.key, required this.editor, required this.entry});
  final EditorModel editor;
  final GalleryEntry entry;

  Gallery get gallery => editor.gallery;

  String get _label {
    if (entry.negative) return 'Negative scan';
    if (entry.video) return 'Video';
    return 'Photo, ${editor.stockById(entry.stock)?['name'] as String? ?? 'Normal'}';
  }

  /// Opens it, its picture flying from the tile: the whole picture as it lies behind the
  /// square, of which the tile shows the middle.
  void _open(BuildContext context, ui.Image? image) {
    LibraryHandoff? handoff;
    final box = context.findRenderObject();
    if (image != null && box is RenderBox && box.attached) {
      final tile = box.size;
      final scale = math.max(tile.width / image.width, tile.height / image.height);
      final whole = Size(image.width * scale, image.height * scale);
      final corner = Offset((tile.width - whole.width) / 2, (tile.height - whole.height) / 2);
      final outward = box.getTransformTo(null);
      handoff = LibraryHandoff(
        image: image,
        rect: MatrixUtils.transformRect(outward, corner & whole),
        window: MatrixUtils.transformRect(outward, Offset.zero & tile),
        path: gallery.pathOf(entry),
      );
    }
    gallery.open(entry, handoff: handoff);
  }

  /// Edit and Delete, and for a scan the roll it is filed in.
  void _menu(BuildContext context, ui.Image? image) => showMenu(context, width: 200, [
        MenuItem(label: 'Edit', onSelected: () => _open(context, image)),
        if (entry.negative)
          MenuItem(label: 'Roll', submenu: [
            for (final roll in gallery.rolls)
              MenuItem(
                label: roll.name,
                description: dayText(roll.day),
                checked: roll.id == entry.roll,
                onSelected: () => gallery.fileIn(entry, roll),
              ),
            if (gallery.rolls.isNotEmpty) const MenuItem.divider(),
            MenuItem(
                label: 'New Roll…',
                onSelected: () => showRollDialog(context, gallery, frame: entry)),
            if (entry.roll != null)
              MenuItem(label: 'Take Out of Roll', onSelected: () => gallery.fileIn(entry, null)),
          ]),
        MenuItem(label: 'Delete', onSelected: () => confirmDelete(context, gallery, entry)),
      ]);

  @override
  Widget build(BuildContext context) {
    final image = gallery.picture(entry);
    return Semantics(
      button: true,
      label: _label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _open(context, image),
        onLongPress: () => _menu(context, image),
        onSecondaryTap: () => _menu(context, image),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: ColoredBox(
            color: const Color(0x0FFFFFFF),
            child: Stack(fit: StackFit.expand, children: [
              if (image != null) EnginePicture(image, fit: BoxFit.cover),
              if (entry.video || entry.negative)
                Positioned(
                  right: 5,
                  bottom: 5,
                  child: _Badge(entry.video ? 'fotu.ui.video' : 'fotu.deck.film'),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A tile's badge: a small white glyph over its own shadow, so it reads on any picture.
class _Badge extends StatelessWidget {
  const _Badge(this.glyph);
  final String glyph;

  @override
  Widget build(BuildContext context) => Stack(children: [
        Transform.translate(
          offset: const Offset(0, .7),
          child: Glyph(glyph, size: 9, color: const Color(0x99000000)),
        ),
        Glyph(glyph, size: 9, color: const Color(0xFFFFFFFF)),
      ]);
}

/// A roll: its first frames as a stack of prints, over its name, its date and how many it
/// holds. It opens to its frames.
class _RollTile extends StatelessWidget {
  const _RollTile({super.key, required this.editor, required this.roll});
  final EditorModel editor;
  final GalleryRoll roll;

  /// How each print of the stack is turned, the top one first.
  static const _turns = [0.0, -.07, .06];

  @override
  Widget build(BuildContext context) {
    final gallery = editor.gallery;
    final frames = gallery.framesOf(roll);
    final covers = frames.take(_turns.length).toList();
    return Semantics(
      button: true,
      label: '${roll.name}, ${dayText(roll.day)}, ${framesText(frames.length)}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => gallery.showRoll(roll),
        onLongPress: () => _menu(context),
        onSecondaryTap: () => _menu(context),
        child: LayoutBuilder(builder: (context, constraints) {
          final side =
              math.min(constraints.maxWidth, constraints.maxHeight - _Sizes.rollLabels) * .78;
          return Column(children: [
            Expanded(
              child: Center(
                child: covers.isEmpty
                    ? const Glyph('fotu.ui.folder', size: 22, color: Color(0x59FFFFFF))
                    : SizedBox.square(
                        dimension: side,
                        child: Stack(fit: StackFit.expand, children: [
                          // The top print is drawn last.
                          for (var i = covers.length - 1; i >= 0; i--)
                            Transform.rotate(
                                angle: _turns[i], child: _Print(gallery.picture(covers[i]))),
                        ]),
                      ),
              ),
            ),
            SizedBox(
              height: _Sizes.rollLabels,
              child: Column(children: [
                Text(roll.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: editorText(context,
                        size: 10.5, weight: FontWeight.w600, color: const Color(0xFFFFFFFF))),
                Text('${dayText(roll.day)} · ${frames.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: editorText(context, size: 9, color: const Color(0xB3FFFFFF))),
              ]),
            ),
          ]);
        }),
      ),
    );
  }

  void _menu(BuildContext context) => showMenu(context, width: 200, [
        MenuItem(label: 'Open', onSelected: () => editor.gallery.showRoll(roll)),
        ...rollMenu(context, editor, roll),
      ]);
}

/// One print of a roll's stack: a frame's picture in a white border, over its shadow.
class _Print extends StatelessWidget {
  const _Print(this.image);
  final ui.Image? image;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1C),
          borderRadius: BorderRadius.circular(2.5),
          boxShadow: const [
            BoxShadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 2)),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2.5),
          border: Border.all(color: const Color(0xD9FFFFFF), width: 1.2),
        ),
        child: image == null
            ? null
            : ClipRRect(
                borderRadius: BorderRadius.circular(2.5),
                child: EnginePicture(image!, fit: BoxFit.cover),
              ),
      );
}
