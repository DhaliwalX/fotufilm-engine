// Scripted checks run on the desktop only; a browser has no directory to read commands from.
export 'driver_stub.dart' if (dart.library.io) 'driver.dart';
