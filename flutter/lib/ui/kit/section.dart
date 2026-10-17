// An inspector section: a quiet, compact Spectrum Disclosure with a bold title, open by default,
// whose controls stack with the editor's control gap.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'buttons.dart';
import 'icons.dart';

class Section extends StatefulWidget {
  const Section({super.key, required this.title, required this.children, this.initiallyOpen = true});
  final String title;
  final List<Widget> children;

  /// Closed at first, as a nested disclosure (Lens Profiles) is.
  final bool initiallyOpen;

  @override
  State<Section> createState() => _SectionState();
}

class _SectionState extends State<Section> with PointerTint {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Padding(
      padding: Metrics.sectionPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        tinted(
          onTap: () => setState(() => _open = !_open),
          child: Container(
            height: Metrics.sectionTitleHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: hovered ? palette.text.withValues(alpha: .05) : null,
              borderRadius: BorderRadius.circular(Metrics.radius),
            ),
            child: Row(children: [
              AppIcon(_open ? 'chevronDown' : 'chevronRight', size: 16, color: palette.text),
              const SizedBox(width: 4),
              Text(widget.title,
                  style: editorText(context, size: TextSizes.section, weight: FontWeight.w700)),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: Metrics.sectionBodyPadding,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < widget.children.length; i++) ...[
                if (i > 0) const SizedBox(height: Metrics.controlGap),
                widget.children[i],
              ],
            ]),
          ),
      ]),
    );
  }
}
