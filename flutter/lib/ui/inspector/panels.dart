// Which sections each inspector panel shows. Each panel lives in its own file; this is the one
// place that names them all.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import 'controls.dart';
import 'crop_panel.dart';
import 'develop_panel.dart';
import 'expose_panel.dart';
import 'film_panel.dart';
import 'negative_panel.dart';
import 'pipeline_panel.dart';
import 'print_panel.dart';
import 'roll_panel.dart';
import 'selective_panel.dart';

List<Widget> panelSections(Panel panel, InspectorControls controls) => switch (panel) {
      // A scanned negative's Film panel is its reading.
      Panel.film when controls.edit['negative'] != null => negativePanel(controls),
      Panel.film => filmPanel(controls),
      Panel.light => exposePanel(controls),
      Panel.develop => developPanel(controls),
      Panel.print => printPanel(controls),
      Panel.roll => rollPanel(controls),
      Panel.crop => cropPanel(controls),
      Panel.selective => selectivePanel(controls),
      Panel.pipeline => pipelinePanel(controls),
    };
