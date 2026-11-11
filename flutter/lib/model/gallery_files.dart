// The gallery's files (gallery.dart): kept in the app's own folder through dart:io. A browser has
// no folder to keep them in, so it has no gallery.
export 'gallery_files_web.dart' if (dart.library.io) 'gallery_files_io.dart';
