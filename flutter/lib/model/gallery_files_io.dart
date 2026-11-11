// The gallery's folder through dart:io: its small records as JSON files, and the photographs
// copied into it. Nothing here throws for a file that has gone; what cannot be written does.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Where this device keeps its gallery, or null where it keeps none. An Android app has its own
/// files (the host points HOME at them); FOTUFILM_GALLERY_DIR names a folder anywhere, for the
/// phone's layout run on a desk.
String? galleryFolder() {
  final named = Platform.environment['FOTUFILM_GALLERY_DIR'];
  if (named != null && named.isNotEmpty) return named;
  final home = Platform.environment['HOME'];
  return Platform.isAndroid && home != null && home.isNotEmpty ? '$home/gallery' : null;
}

/// Every record in `folder` (its `.json` files); one that cannot be read is left out.
List<Map<String, dynamic>> readRecords(String folder) {
  final directory = Directory(folder);
  if (!directory.existsSync()) return const [];
  return [
    for (final entry in directory.listSync(followLinks: false))
      if (entry is File && entry.path.endsWith('.json'))
        if (readRecord(entry.path) case final Map<String, dynamic> record) record,
  ];
}

/// The record at `path`, or null when there is none or it cannot be read.
Object? readRecord(String path) {
  try {
    return jsonDecode(File(path).readAsStringSync());
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Writes the record at `path`, whole or not at all; null removes it.
void writeRecord(String path, Object? record) {
  if (record == null) return removeFile(path);
  final file = File(path)..parent.createSync(recursive: true);
  File('$path.new')
    ..writeAsStringSync(jsonEncode(record), flush: true)
    ..renameSync(file.path);
}

bool isFile(String path) => FileSystemEntity.isFileSync(path);

/// A name in `folder` no file has: `name`, or `name` with a number before its extension.
String _free(String folder, String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name, tail = dot > 0 ? name.substring(dot) : '';
  var candidate = name;
  for (var n = 2;
      FileSystemEntity.typeSync('$folder/$candidate') != FileSystemEntityType.notFound;
      n++) {
    candidate = '$stem $n$tail';
  }
  return candidate;
}

/// Copies the file at `from` into `folder` as `name`, or the nearest name that is free, and
/// answers the name it took.
Future<String> copyInto(String folder, String from, String name) async {
  await Directory(folder).create(recursive: true);
  final taken = _free(folder, name);
  await File(from).copy('$folder/$taken');
  return taken;
}

/// Moves the file at `from` into `folder` under its own name, or the nearest name that is free,
/// and answers the name it took.
String moveInto(String folder, String from) {
  Directory(folder).createSync(recursive: true);
  final taken = _free(folder, from.substring(from.lastIndexOf('/') + 1));
  File(from).renameSync('$folder/$taken');
  return taken;
}

Future<void> writeBytes(String path, Uint8List bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await File('$path.new').writeAsBytes(bytes, flush: true);
  await File('$path.new').rename(file.path);
}

Future<Uint8List?> readBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } on FileSystemException {
    return null;
  }
}

void removeFile(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

/// Removes a folder and what is in it; with `onlyEmpty`, only a folder with nothing in it.
void removeFolder(String path, {bool onlyEmpty = false}) {
  try {
    Directory(path).deleteSync(recursive: !onlyEmpty);
  } on FileSystemException {
    // Already gone, or not empty.
  }
}
