// Fotufilm's editor drawn by Flutter in the React editor's layout and look (web/src), from one UI
// on the desktop and in a browser. The desktop calls libfotufilm through dart:ffi on its own
// isolate and presents its pictures straight into platform textures; a browser calls the web
// editor's WASM and WebGPU engine through web/src/flutter-bridge.js.
//
//   app/      the window: workspace layout, commands and menus, the host window
//   model/    the editor's state, what the engine develops, and the control catalogue
//   engine/   the engine connection (native and browser) and the native presenter
//   ui/       theme (colours, sizes, type), kit (controls), workspace and inspector
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/host_window.dart';
import 'debug/debug.dart';
import 'model/catalogue.dart';
import 'model/cef_profile.dart';
import 'model/editor.dart';
import 'ui/kit/icons.dart';
import 'ui/workspace/picture.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final (catalogue, _, _, settings) =
      await (Catalogue.load(), IconLibrary.load(), ColourConversion.load(), AppSettings.load())
          .wait;
  // What the CEF app kept comes over before the features read their settings.
  importCefProfile(settings);
  final editor = EditorModel(catalogue, settings: settings);
  final boundary = GlobalKey();
  runApp(RepaintBoundary(key: boundary, child: FotufilmApp(editor: editor)));
  await editor.start();
  unawaited(resolveCefEdits(editor));
  // A browser engine answers in sRGB; the desktop engine's Display P3 is converted for drawing.
  ColourConversion.enabled = editor.engine?.picturesAreDisplayP3 ?? true;
  Driver.start(editor, boundary);
  // Photographs from the Finder or the command line, then as they arrive.
  await editor.openPaths(
      await HostWindow.takeOpenedFiles(editor.openPaths, arguments: arguments));
}
