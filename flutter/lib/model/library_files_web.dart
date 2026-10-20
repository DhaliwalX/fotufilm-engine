// Library folders in a browser, through the bridge (web/src/photo-library/browser-folders.js):
// a folder is named `/folders/<id>/<name>` and the browser reads its files in place, by their
// path below that. Nothing is renamed or moved.
import '../engine/engine.dart';
import '../engine/engine_web.dart';
import 'library_model.dart';

/// Whether an opened file's own folder can be listed (an opened file has no path in a browser).
const libraryFilesAvailable = false;

const _root = '/folders/';

/// A folder chosen in the browser's folder picker, or null when it was dismissed.
Future<String?> chooseFolder() async =>
    (await callBridge('chooseFolder')).json['path'] as String?;

/// Lets go of a removed folder's access.
Future<void> forgetFolder(String folder) => callBridge('forgetFolder', {'path': folder});

Future<List<FileRow>> listFolder(String folder, {bool recursive = true}) async {
  final rows = (await callBridge('listFolder', {'path': folder})).json['rows'] as List;
  return [
    for (final row in rows.cast<List>())
      if (recursive || !(row[0] as String).contains('/'))
        (row[0] as String, (row[1] as num).toInt(), (row[2] as num).toInt()),
  ];
}

String renameFile(String path, String name) =>
    throw UnsupportedError('Files are renamed on the desktop.');

bool isFolder(String path) => path.startsWith(_root);

/// Whether a file is still there is found when it is read.
bool isFile(String path) => path.startsWith(_root);

String fileProblem(Object error) => error is FotufilmException ? error.message : '$error';

/// Why a folder could not be listed: the browser says (permission, a forgotten upload).
String folderProblem(String folder, Object error) => fileProblem(error);
