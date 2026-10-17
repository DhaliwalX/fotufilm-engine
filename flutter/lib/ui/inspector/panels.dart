// Which sections each inspector panel shows (EditorInspector.jsx). Each panel lives in its own
// file; this is the one place that names them all.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import 'controls.dart';
import 'develop_panel.dart';
import 'expose_panel.dart';
import 'film_panel.dart';
import 'print_panel.dart';

List<Widget> panelSections(Panel panel, InspectorControls controls) => switch (panel) {
      Panel.film => filmPanel(controls),
      Panel.light => exposePanel(controls),
      Panel.develop => developPanel(controls),
      Panel.print => printPanel(controls),
      Panel.roll => const [],
      Panel.crop => const [],
      Panel.selective => const [],
      Panel.pipeline => const [],
    };
