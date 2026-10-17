// Spectrum's SegmentedControl, justified: a grey track with the selection as a raised white pill.
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      height: Metrics.segmentedHeight,
      decoration: BoxDecoration(color: palette.gray100, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        for (final (value, label) in items)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(value),
              child: Container(
                alignment: Alignment.center,
                decoration: value == selected
                    ? BoxDecoration(
                        color: palette.gray25,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const [
                          BoxShadow(color: Color(0x29000000), blurRadius: 3, offset: Offset(0, 1)),
                          BoxShadow(color: Color(0x0F000000), spreadRadius: .5),
                        ],
                      )
                    : null,
                child: Text(label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: editorText(context,
                        size: TextSizes.heading - 1,
                        color: value == selected ? palette.text : palette.text.withValues(alpha: .7))),
              ),
            ),
          ),
      ]),
    );
  }
}
