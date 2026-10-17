// The app: the editor's palette for the system's appearance, around the workspace.
import 'dart:io';

import 'package:flutter/material.dart' show MaterialApp, ThemeData;
import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../ui/theme/theme.dart';
import 'workspace.dart';

class FotufilmApp extends StatelessWidget {
  const FotufilmApp({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    // The editor follows the system's appearance; FOTUFILM_APPEARANCE=light|dark overrides it.
    final forced = Platform.environment['FOTUFILM_APPEARANCE'];
    final dark = forced == null || forced.isEmpty
        ? MediaQuery.platformBrightnessOf(context) == Brightness.dark
        : forced == 'dark';
    return MaterialApp(
      title: 'Fotufilm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: editorFont, useMaterial3: true),
      home: PaletteScope(
        palette: dark ? Palette.darkPalette : Palette.light,
        child: Workspace(editor: editor),
      ),
    );
  }
}
