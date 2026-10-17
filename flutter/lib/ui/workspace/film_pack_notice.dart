// What an import did, as the Mac app's alert says it (web/src/editor/FilmPackNotice.jsx): "Pack
// added" with the pack and its films, "Pack not added" and why, or that the pack needs a newer
// Fotufilm, which offers the update.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/film_packs.dart';
import 'app_dialogs.dart';

/// Import Film Pack…: packs chosen in the open panel go in, and the notice says what happened.
Future<void> chooseFilmPacks(EditorModel editor) async {
  if (!editor.filmPacks.available || editor.exporting) return;
  final files = await openFiles(acceptedTypeGroups: const [
    XTypeGroup(label: 'Film packs', extensions: [filmPackExtension]),
  ]);
  await editor.filmPacks.importPaths([for (final f in files) f.path]);
}

class FilmPackNotice extends StatelessWidget {
  const FilmPackNotice({super.key, required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final notice = editor.filmPacks.notice;
    if (notice == null) return const SizedBox.shrink();
    final offerUpdate = notice.update && editor.updates.available;
    return AlertCard(
      title: notice.title,
      message: notice.message,
      warning: !notice.added,
      primary: offerUpdate ? 'Check for Updates…' : 'OK',
      onPrimary: () {
        onClose();
        if (offerUpdate) editor.updates.check();
      },
      cancel: offerUpdate ? 'Later' : null,
      onCancel: onClose,
    );
  }
}
