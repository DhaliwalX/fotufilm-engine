// Spectrum's Menu, small: rows with an optional icon, a checkmark on the chosen one, and a
// shortcut on the right. Pickers and the toolbar's menus open it under their button. A row with
// a submenu (Edit History, Presets) shows it in the same popover, under a row that goes back.
// A menu with selectable rows (Spectrum's selectionMode) keeps a column before the icons for
// their checkmarks, or checkboxes where several may be chosen; a description goes under its
// label, and a link out of the app shows Spectrum's link-out arrow.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/theme.dart';
import 'buttons.dart';
import 'icons.dart';
import 'popover.dart';

/// How a row is chosen (Spectrum's `selectionMode`): one of its menu, or any of them.
enum MenuSelection { single, multiple }

class MenuItem {
  const MenuItem(
      {required this.label,
      this.onSelected,
      this.checked,
      this.icon,
      this.detail,
      this.submenu,
      this.selection,
      this.description,
      this.link = false})
      : divider = false;
  const MenuItem.divider()
      : label = '',
        onSelected = null,
        checked = null,
        icon = null,
        detail = null,
        submenu = null,
        selection = null,
        description = null,
        link = false,
        divider = true;

  final String label;
  final VoidCallback? onSelected;

  /// Whether the row is chosen: a checkmark at its end, or with [selection] in the menu's
  /// checkmark column.
  final bool? checked;
  final String? icon, detail;
  final bool divider;

  /// The row is selectable, its checkmark (or checkbox) before its icon.
  final MenuSelection? selection;

  /// A line under the label (Spectrum's `slot="description"`).
  final String? description;

  /// Opens a page outside the app.
  final bool link;

  /// The rows a submenu holds; the row opens it rather than running.
  final List<MenuItem>? submenu;
}

/// Opens a menu under the widget of `anchor`.
void showMenu(BuildContext anchor, List<MenuItem> items,
        {bool alignEnd = false, double? width, bool matchWidth = false, bool above = false}) =>
    showAnchored(
      anchor,
      (context, close) => MenuList(items: items, onClose: close),
      alignEnd: alignEnd,
      width: width ?? 220,
      matchWidth: matchWidth,
      above: above,
    );

class MenuList extends StatefulWidget {
  const MenuList({super.key, required this.items, required this.onClose});
  final List<MenuItem> items;
  final VoidCallback onClose;

  @override
  State<MenuList> createState() => _MenuListState();
}

class _MenuListState extends State<MenuList> {
  /// The submenu on show, if any.
  MenuItem? _sub;

  VoidCallback get onClose => widget.onClose;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final sub = _sub;
    final back = sub == null ? null : MenuItem(label: sub.label, icon: 'chevronLeft');
    final items = [
      if (back != null) ...[back, const MenuItem.divider()],
      ...?(sub == null ? widget.items : sub.submenu),
    ];
    // Spectrum's menu grid gives every row the checkmark column once any row needs it.
    final checks = items.any((i) => i.selection != null && i.submenu == null);
    // The arrow keys move through the rows, as a menu's do; Return chooses (KeyTarget).
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(child: PopoverSurface(
      child: ConstrainedBox(
        // As tall as the window allows below the toolbar, as Spectrum's popover is.
        constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height - 72).clamp(240, double.infinity)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final item in items)
              if (item.divider)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
                  child: Container(height: 1, color: palette.border.withValues(alpha: .7)),
                )
              else if (identical(item, back))
                _MenuRow(
                    item: item,
                    onClose: () => setState(() => _sub = null),
                    back: true,
                    checks: checks)
              else if (item.submenu != null)
                _MenuRow(item: item, onClose: () => setState(() => _sub = item), checks: checks)
              else
                _MenuRow(item: item, onClose: onClose, checks: checks),
          ]),
        ),
      ),
    )),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow(
      {required this.item, required this.onClose, this.back = false, this.checks = false});
  final MenuItem item;
  final VoidCallback onClose;

  /// The menu keeps a checkmark column.
  final bool checks;

  /// The row that leaves a submenu: it only goes back.
  final bool back;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final item = widget.item;
    final enabled =
        widget.back || item.onSelected != null || (item.submenu?.isNotEmpty ?? false);
    return tinted(
      onTap: enabled
          ? () {
              widget.onClose();
              if (!widget.back) item.onSelected?.call();
            }
          : null,
      label: widget.back
          ? 'Back to ${item.label}'
          : [item.label, ?item.description, ?item.detail].join(', '),
      selected: item.checked,
      radius: 5,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hovered && enabled ? palette.hover : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Opacity(
          opacity: enabled ? 1 : .4,
          child: Row(children: [
            if (widget.checks) ...[
              SizedBox(width: 14, child: _selectionMark(palette, item)),
              const SizedBox(width: 8),
            ],
            if (item.icon != null) ...[
              AppIcon(item.icon!, size: 16),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: item.description == null
                  ? Text(item.label, style: editorText(context, size: TextSizes.menu))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.label, style: editorText(context, size: TextSizes.menu)),
                      const SizedBox(height: 2),
                      Text(item.description!,
                          style: editorText(context, size: TextSizes.label, color: palette.muted)),
                    ]),
            ),
            if (item.detail != null) ...[
              const SizedBox(width: 12),
              Text(item.detail!, style: editorText(context, color: palette.muted)),
            ],
            if (item.checked == true && item.selection == null) ...[
              const SizedBox(width: 8),
              AppIcon('check', size: 14, color: palette.accent),
            ],
            if (item.link) ...[
              const SizedBox(width: 8),
              _spectrumIcon(_linkOut, 10, palette.text),
            ],
            if (item.submenu != null) ...[
              const SizedBox(width: 8),
              AppIcon('chevronRight', size: 14, color: palette.muted),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The checkmark column's mark: Spectrum's checkmark in the accent for a chosen row of a single
/// choice, a checkbox for one of several.
Widget? _selectionMark(Palette palette, MenuItem item) {
  final chosen = item.checked == true;
  return switch (item.selection) {
    MenuSelection.single when chosen => _spectrumIcon(_checkmark, 12, palette.accent),
    MenuSelection.multiple => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: chosen ? palette.gray800 : null,
          border: chosen ? null : Border.all(color: palette.text.withValues(alpha: .55), width: 1.5),
          borderRadius: BorderRadius.circular(3),
        ),
        child: chosen ? Center(child: _spectrumIcon(_checkmark, 9, palette.onSelected)) : null,
      ),
    _ => null,
  };
}

// Spectrum 2's UI icons at size 100 (S2_CheckmarkSize100, S2_LinkOutSize100).
const _checkmark = 'M3.5 9.503c-.3 0-.584-.135-.774-.367l-2.45-3A1 1 0 1 1 1.823 4.87L3.481 6.9 '
    '8.161.888A1 1 0 0 1 9.74 2.118l-5.45 7a1 1 0 0 1-.777.385z';
const _linkOut = 'M8.125 1H3.741a.875.875 0 1 0 0 1.75h2.27l-4.88 4.88a.88.88 0 0 0 0 1.24.873.873 '
    '0 0 0 1.238 0L7.25 3.987v2.27a.875.875 0 1 0 1.75 0V1.876A.875.875 0 0 0 8.125 1';

Widget _spectrumIcon(String path, double size, Color color) => SvgPicture.string(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="$path"/></svg>',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
