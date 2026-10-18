// The library's folders read in place: on the desktop through dart:io, and not at all in a browser.
export 'library_files_web.dart' if (dart.library.io) 'library_files_io.dart';
