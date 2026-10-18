import 'package:flutter/widgets.dart';

import '../model/editor.dart';

abstract final class Driver {
  static void start(EditorModel editor, GlobalKey boundary) {}
}
