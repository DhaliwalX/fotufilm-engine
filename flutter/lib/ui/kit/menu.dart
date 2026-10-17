// Spectrum's Menu, small: rows with an optional icon, a checkmark on the chosen one, and a
// shortcut on the right. Pickers and the toolbar's menus open it under their button. A row with
// a submenu (Edit History, Presets) shows it in the same popover, under a row that goes back.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'buttons.dart';
import 'icons.dart';
import 'popover.dart';

class MenuItem {
  const MenuItem(
      {required this.label, this.onSelected, this.checked, this.icon, this.detail, this.submenu})
      : divider = false;
  const MenuItem.divider()
      : label = '',
        onSelected = null,
        checked = null,
        icon = null,
        detail = null,
        submenu = null,
        divider = true;

  final String label;
  final VoidCallback? onSelected;
  final bool? checked;
  final String? icon, detail;
  final bool divider;

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
    return PopoverSurface(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
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
                _MenuRow(item: item, onClose: () => setState(() => _sub = null), back: true)
              else if (item.submenu != null)
                _MenuRow(item: item, onClose: () => setState(() => _sub = item))
              else
                _MenuRow(item: item, onClose: onClose),
          ]),
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({required this.item, required this.onClose, this.back = false});
  final MenuItem item;
  final VoidCallback onClose;

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
            if (item.icon != null) ...[
              AppIcon(item.icon!, size: 16),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(item.label, style: editorText(context, size: TextSizes.menu))),
            if (item.detail != null) ...[
              const SizedBox(width: 12),
              Text(item.detail!, style: editorText(context, color: palette.muted)),
            ],
            if (item.checked == true) ...[
              const SizedBox(width: 8),
              AppIcon('check', size: 14, color: palette.accent),
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
