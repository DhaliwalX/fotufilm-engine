// The file types an Open panel offers. GTK matches a type's patterns case-sensitively, so on
// Linux the upper-case spellings cameras write (.ARW, .NEF, .JPG) are listed beside the lower.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

XTypeGroup fileType(String label, List<String> extensions) => XTypeGroup(
      label: label,
      extensions: defaultTargetPlatform == TargetPlatform.linux && !kIsWeb
          ? [...extensions, for (final e in extensions) e.toUpperCase()]
          : extensions,
    );
