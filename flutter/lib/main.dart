// Fotufilm's desktop editor drawn natively by Flutter: the React editor's layout and look
// (web/src), with the engine (libfotufilm) called through dart:ffi on its own isolate and its
// pictures presented straight into platform textures.
//
//   app/      the window: workspace layout, commands and menus, the host window
//   model/    the editor's state, what the engine develops, and the control catalogue
//   engine/   the C ABI, the engine isolate and the native presenter
//   ui/       theme (colours, sizes, type), kit (controls), workspace and inspector
import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/host_window.dart';
import 'debug/driver.dart';
import 'model/catalogue.dart';
import 'model/editor.dart';
import 'ui/kit/icons.dart';
import 'ui/workspace/picture.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final (catalogue, _, _) =
      await (Catalogue.load(), IconLibrary.load(), ColourConversion.load()).wait;
  final editor = EditorModel(catalogue);
  final boundary = GlobalKey();
  runApp(RepaintBoundary(key: boundary, child: FotufilmApp(editor: editor)));
  await editor.start();
  Driver.start(editor, boundary);
  // Photographs from the Finder or the command line, then as they arrive.
  await editor.openPaths(
      await HostWindow.takeOpenedFiles(editor.openPaths, arguments: arguments));
}
