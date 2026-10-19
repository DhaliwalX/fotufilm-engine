// The app: the editor's palette for the system's appearance, around the workspace, drawn larger
// on a phone.
import 'package:flutter/material.dart' show MaterialApp, ThemeData;
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../ui/theme/theme.dart';
import 'environment.dart';
import 'touch_scale.dart';
import 'workspace.dart';

class FotufilmApp extends StatelessWidget {
  const FotufilmApp({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    // The editor follows the system's appearance; FOTUFILM_APPEARANCE=light|dark overrides it
    // (an environment variable on the desktop, a query parameter in a browser).
    final forced = environment('FOTUFILM_APPEARANCE');
    final dark = forced == null || forced.isEmpty
        ? MediaQuery.platformBrightnessOf(context) == Brightness.dark
        : forced == 'dark';
    return MaterialApp(
      title: 'Fotufilm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: editorFont, useMaterial3: true),
      // A phone draws everything larger, the menus and dialogs too (touch_scale.dart).
      builder: (context, child) => TouchScale(child: child!),
      home: PaletteScope(
        palette: dark ? Palette.darkPalette : Palette.light,
        child: Workspace(editor: editor),
      ),
    );
  }
}
