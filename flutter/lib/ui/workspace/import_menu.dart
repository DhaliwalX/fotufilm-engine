// The toolbar's Add media button (web/src/editor/ImportMenu.jsx): a menu of what to import, an
// image, a video or a scanned negative, and exposures to merge into trichromatic scans.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

class ImportMenu extends StatelessWidget {
  const ImportMenu(
      {super.key, required this.editor, required this.onImage, this.size = Metrics.control});
  final EditorModel editor;
  final VoidCallback onImage;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scans = editor.negatives;
    return Builder(
      builder: (anchor) => QuietButton(
        icon: 'plus',
        tooltip: 'Add media',
        size: size,
        opensMenu: true,
        onPressed: editor.exporting
            ? null
            : () => showMenu(anchor, width: 200, [
                  MenuItem(label: 'Image', onSelected: editor.ready ? onImage : null),
                  MenuItem(
                      label: 'Video',
                      onSelected: editor.ready ? editor.video.chooseMovies : null),
                  MenuItem(
                      label: 'Negative',
                      onSelected: scans.canImport ? scans.chooseNegatives : null),
                  if (editor.engine?.opensPaths ?? true)
                    MenuItem(
                        label: 'Trichromatic Negative',
                        onSelected: scans.canMerge ? scans.chooseExposures : null),
                ]),
      ),
    );
  }
}
