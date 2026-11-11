// The file types an Open panel offers, and where a Save panel says a file goes. GTK matches a
// type's patterns case-sensitively, so on Linux the upper-case spellings cameras write (.ARW,
// .NEF, .JPG) are listed beside the lower.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

/// Files chosen in the system's open panel. On Android, the activity's own picker
/// (OpenedFiles.kt), showing the files of the `android` media types: file_selector holds each
/// chosen file in memory on its way across, which a camera's RAW or a scan runs out of, where the
/// activity copies each into the cache and answers its path. With `single`, the panel takes one
/// file.
Future<List<XFile>> chooseFiles(List<XTypeGroup> groups,
    {String? confirmButtonText,
    List<String> android = const ['image/*', 'video/*'],
    bool single = false}) async {
  if (_android) {
    final paths = await _androidFiles
            .invokeListMethod<String>('open', {'types': android, 'single': single}) ??
        const [];
    return [for (final path in paths) XFile(path, name: path.split('/').last)];
  }
  if (single) {
    final file = await openFile(acceptedTypeGroups: groups, confirmButtonText: confirmButtonText);
    return [?file];
  }
  return openFiles(acceptedTypeGroups: groups, confirmButtonText: confirmButtonText);
}

const _androidFiles = MethodChannel('fotufilm/files');

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Where a file, or a folder of files, is saved: `path` is written, then [finish]ed. On Android
/// the system's panel answers a document, not a path: `path` is then in the app's cache, and
/// finishing moves what was written there into the document (OpenedFiles.kt).
class SaveLocation {
  const SaveLocation(this.path, {this.document});
  final String path;

  /// The document, or the folder, chosen on Android.
  final String? document;

  /// Once `path` is written. Answers the name the system saved it under, where it is not
  /// `path`'s own.
  Future<String?> finish() async {
    if (document == null) return null;
    try {
      return await _androidFiles.invokeMethod<String>('save', {'path': path, 'document': document});
    } on PlatformException catch (e) {
      throw SaveFailed(e.message ?? 'The file could not be saved.');
    }
  }

  /// When `path` could not be written: nothing is left where it was to go.
  Future<void> discard() async {
    if (document == null) return;
    try {
      await _androidFiles.invokeMethod<void>('discard', {'path': path, 'document': document});
    } on PlatformException {
      // What is left is an empty document.
    }
  }
}

/// A file written in the app that did not reach the document chosen for it.
class SaveFailed implements Exception {
  const SaveFailed(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where the system's save panel says a file named `name` goes; null when it is cancelled.
/// `mediaType` is what Android's panel makes the document as.
Future<SaveLocation?> chooseSaveFile(String name,
    {List<XTypeGroup> types = const [], String mediaType = ''}) async {
  if (_android) {
    return _chosen(await _androidFiles
        .invokeMapMethod<String, String>('create', {'name': name, 'type': mediaType}));
  }
  final location = await getSaveLocation(suggestedName: name, acceptedTypeGroups: types);
  return location == null ? null : SaveLocation(location.path);
}

/// The folder the system's panel says files go into; null when it is cancelled.
Future<SaveLocation?> chooseSaveFolder({String? confirmButtonText}) async {
  if (_android) return _chosen(await _androidFiles.invokeMapMethod<String, String>('folder'));
  final path = await getDirectoryPath(confirmButtonText: confirmButtonText);
  return path == null ? null : SaveLocation(path);
}

SaveLocation? _chosen(Map<String, String>? answer) =>
    answer == null ? null : SaveLocation(answer['path']!, document: answer['document']);

XTypeGroup fileType(String label, List<String> extensions) => XTypeGroup(
      label: label,
      extensions: defaultTargetPlatform == TargetPlatform.linux && !kIsWeb
          ? [...extensions, for (final e in extensions) e.toUpperCase()]
          : extensions,
    );
