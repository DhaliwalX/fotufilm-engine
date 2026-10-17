// Launch settings: environment variables on the desktop (FOTUFILM_APPEARANCE=dark), the page's
// query in a browser (?FOTUFILM_APPEARANCE=dark).
export 'environment_web.dart' if (dart.library.io) 'environment_io.dart';
