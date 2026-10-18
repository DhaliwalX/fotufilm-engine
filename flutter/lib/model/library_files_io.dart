// Library folders through dart:io: a folder's photos listed in one call off the UI isolate, and a
// photo renamed in its folder.
import 'dart:io';
import 'dart:isolate';

import 'library_model.dart';

const libraryFilesAvailable = true;

/// Every file under `folder` the library shows, depth first, as [FileRow]s relative to it.
/// Hidden files and folders are left out, and an entry that vanishes or cannot be read is
/// skipped; a folder that cannot be read at all throws. With `recursive` false, only the files
/// directly in `folder` (`listOpenedFolder`).
Future<List<FileRow>> listFolder(String folder, {bool recursive = true}) =>
    Isolate.run(() => _list(folder, recursive));

List<FileRow> _list(String folder, bool recursive) {
  final root = Directory(folder);
  final rows = <FileRow>[];
  void walk(Directory directory, String prefix) {
    for (final entry in directory.listSync(followLinks: false)) {
      final name = entry.path.substring(entry.path.lastIndexOf('/') + 1);
      if (name.isEmpty || name.startsWith('.')) continue;
      final path = prefix.isEmpty ? name : '$prefix/$name';
      // A link counts as what it points to, as the host's walk follows links to files.
      final type = entry is Link ? FileSystemEntity.typeSync(entry.path) : entry.statSync().type;
      if (type == FileSystemEntityType.directory) {
        // Links to folders are not followed, so a loop cannot trap the walk.
        if (recursive && entry is Directory) {
          try {
            walk(entry, path);
          } on FileSystemException {
            // A subfolder that cannot be read is left out.
          }
        }
        continue;
      }
      if (type != FileSystemEntityType.file) continue;
      final dot = name.lastIndexOf('.');
      if (dot < 0 || !libraryExtensions.contains(name.substring(dot + 1).toLowerCase())) continue;
      final stat = FileStat.statSync(entry.path);
      if (stat.type == FileSystemEntityType.notFound) continue;
      rows.add((path, stat.size, stat.modified.millisecondsSinceEpoch));
    }
  }

  walk(root, '');
  return rows;
}

/// Renames the file at `path` to `name` in the same folder and answers its new path. Throws a
/// [FileSystemException] whose message says why not (LibraryFolders::Rename).
String renameFile(String path, String name) {
  final from = File(path);
  if (!from.existsSync()) throw const FileSystemException('The photo is no longer in its folder.');
  if (name.isEmpty || name.startsWith('.') || name.length > 255 ||
      RegExp(r'[/\\:\n\x00]').hasMatch(name)) {
    throw const FileSystemException('Use a name without “/” or “:” that does not start with a dot.');
  }
  final to = '${path.substring(0, path.lastIndexOf('/'))}/$name';
  // A change of case only is the same file on a case-insensitive volume.
  if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound &&
      !FileSystemEntity.identicalSync(path, to)) {
    throw FileSystemException('Another file is already named “$name”.');
  }
  return from.renameSync(to).path;
}

bool isFolder(String path) => FileSystemEntity.isDirectorySync(path);

bool isFile(String path) => FileSystemEntity.isFileSync(path);

/// What went wrong with a file, in words for the library's notice.
String fileProblem(Object error) => error is FileSystemException ? error.message : '$error';
