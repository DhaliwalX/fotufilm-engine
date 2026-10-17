// The panels' controls that change with the window (web/src/editor/InspectorRail.jsx,
// PanelDismissButton.jsx, FilmSidebarToggle.jsx, styles/phone-layout.css): the film library's
// sidebar toggle, the compact layout's rail of labelled panel buttons along the bottom, and the
// close button on each of its docks.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/panel_layout.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

/// Collapses or expands the film library; in the compact layout it closes the film dock.
class FilmSidebarToggle extends StatelessWidget {
  const FilmSidebarToggle({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => QuietButton(
        icon: 'sidebar',
        tooltip: editor.filmOpen ? 'Collapse films' : 'Expand films',
        selected: editor.filmOpen,
        onPressed: () {
          editor.endEdit();
          editor.toggleFilm();
        },
      );
}

/// The compact film list's Film settings: the Film panel, in the inspector's dock.
class FilmSettingsButton extends StatelessWidget {
  const FilmSettingsButton({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => editor.layout.compact
      ? QuietButton(
          icon: 'adjustments',
          tooltip: 'Film settings',
          onPressed: editor.layout.filmSettings,
        )
      : const SizedBox.shrink();
}

/// A compact dock's close button; nothing in the side-by-side layout.
class PanelDismissButton extends StatelessWidget {
  const PanelDismissButton({super.key, required this.editor, required this.side});
  final EditorModel editor;
  final PanelSide side;

  @override
  Widget build(BuildContext context) => editor.layout.compact
      ? QuietButton(
          icon: 'close',
          tooltip: side == PanelSide.film ? 'Close film library' : 'Close adjustments',
          size: Metrics.compactTouch,
          onPressed: () => editor.layout.dismiss(side),
        )
      : const SizedBox.shrink();
}

/// The compact layout's rail: each panel's icon over its name, across the bottom. The Film button
/// opens the film list's dock, and reads as chosen while that is open.
class CompactRail extends StatelessWidget {
  const CompactRail({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      color: palette.panel,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      alignment: Alignment.topCenter,
      child: Row(children: [
        for (final p in editor.inspectorTabs)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _RailButton(
                panel: p,
                selected: editor.filmOpen ? p == Panel.film : editor.panel == p,
                onPressed: () => editor.layout.railPressed(p),
              ),
            ),
          ),
      ]),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({required this.panel, required this.selected, required this.onPressed});
  final Panel panel;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final fg = widget.selected ? palette.onSelected : palette.text;
    return HoverTip(
      message: widget.panel.title,
      child: tinted(
        onTap: widget.onPressed,
        child: Container(
          height: Metrics.compactRailButton,
          decoration: BoxDecoration(
            color: widget.selected
                ? palette.gray800
                : pressed
                    ? palette.pressed
                    : hovered
                        ? palette.hover
                        : null,
            borderRadius: BorderRadius.circular(Metrics.radius),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AppIcon(widget.panel.icon, size: Metrics.icon, color: fg),
            const SizedBox(height: 3),
            Text(widget.panel.title,
                style: editorText(context,
                    size: TextSizes.label, weight: FontWeight.w500, color: fg)),
          ]),
        ),
      ),
    );
  }
}
