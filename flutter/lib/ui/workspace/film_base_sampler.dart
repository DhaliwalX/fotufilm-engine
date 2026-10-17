// Pick Clear Film (NegativeInspector.jsx, useSceneSampling.js): while it is on, the photograph
// takes a precise cursor, and a click samples the clear film under it for the scan's reading.
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
            onTapUp: (d) => editor.negatives.sampleFilmBase(Offset(
                d.localPosition.dx / constraints.maxWidth,
                d.localPosition.dy / constraints.maxHeight)),
          ),
        ),
      );
}
