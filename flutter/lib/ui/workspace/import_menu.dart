// The toolbar's Add media button: a menu of what to import, an image, a video or a scanned
// negative, and exposures to merge into trichromatic scans. The phone's gallery lists the same
// under its own button.
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
  Widget build(BuildContext context) => Builder(
        builder: (anchor) => QuietButton(
          icon: 'plus',
          tooltip: 'Add media',
          size: size,
          opensMenu: true,
          onPressed: editor.exporting ? null : () => showImportMenu(anchor, editor, onImage),
        ),
      );
}

/// The menu of what to import, under `anchor`.
void showImportMenu(BuildContext anchor, EditorModel editor, VoidCallback onImage) =>
    showMenu(anchor, width: 200, importMenuItems(editor, onImage));

/// What can be imported: an image, a video, and the kinds of scan. With `roll`, the scans chosen
/// are filed in that roll of the gallery.
List<MenuItem> importMenuItems(EditorModel editor, VoidCallback onImage, {GalleryRoll? roll}) => [
      MenuItem(label: 'Image', onSelected: editor.ready ? onImage : null),
      MenuItem(label: 'Video', onSelected: editor.ready ? editor.video.chooseMovies : null),
      ...scanMenuItems(editor, roll: roll),
    ];

/// The kinds of scan to import: a negative, and exposures to merge where files have paths.
List<MenuItem> scanMenuItems(EditorModel editor, {GalleryRoll? roll}) {
  final scans = editor.negatives;
  VoidCallback choose(Future<void> Function() chooser) =>
      roll == null ? chooser : () => editor.gallery.addFrames(roll, chooser);
  return [
    MenuItem(
        label: 'Negative', onSelected: scans.canImport ? choose(scans.chooseNegatives) : null),
    if (editor.engine?.opensPaths ?? true)
      MenuItem(
          label: 'Trichromatic Negative',
          onSelected: scans.canMerge ? choose(scans.chooseExposures) : null),
  ];
}
