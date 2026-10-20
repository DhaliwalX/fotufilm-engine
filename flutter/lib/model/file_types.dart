// The file types an Open panel offers. GTK matches a type's patterns case-sensitively, so on
// Linux the upper-case spellings cameras write (.ARW, .NEF, .JPG) are listed beside the lower.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

/// Files chosen in the system's open panel. On Android, the activity's own picker
/// (OpenedFiles.kt), showing the files of the `android` media types: file_selector holds each
/// chosen file in memory on its way across, which a camera's RAW or a scan runs out of, where the
/// activity copies each into the cache and answers its path.
Future<List<XFile>> chooseFiles(List<XTypeGroup> groups,
    {String? confirmButtonText, List<String> android = const ['image/*', 'video/*']}) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final paths =
        await _androidFiles.invokeListMethod<String>('open', {'types': android}) ?? const [];
    return [for (final path in paths) XFile(path, name: path.split('/').last)];
  }
  return openFiles(acceptedTypeGroups: groups, confirmButtonText: confirmButtonText);
}

const _androidFiles = MethodChannel('fotufilm/files');

XTypeGroup fileType(String label, List<String> extensions) => XTypeGroup(
      label: label,
      extensions: defaultTargetPlatform == TargetPlatform.linux && !kIsWeb
          ? [...extensions, for (final e in extensions) e.toUpperCase()]
          : extensions,
    );
