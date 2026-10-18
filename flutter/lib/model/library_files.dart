// The library's folders read in place: on the desktop through dart:io, in a browser through the
// bridge's folder access (web/src/photo-library/browser-folders.js).
export 'library_files_web.dart' if (dart.library.io) 'library_files_io.dart';
