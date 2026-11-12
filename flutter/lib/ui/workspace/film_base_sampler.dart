// Pick Clear Film and Pick Neutral: while one is on, the photograph takes a precise cursor, and a
// click samples the scan under it for the reading.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';

class FilmBaseSampler extends StatelessWidget {
  const FilmBaseSampler({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => editor.negatives.sample(Offset(
                d.localPosition.dx / constraints.maxWidth,
                d.localPosition.dy / constraints.maxHeight)),
          ),
        ),
      );
}
