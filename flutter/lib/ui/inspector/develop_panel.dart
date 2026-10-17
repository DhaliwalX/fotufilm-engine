// The Develop panel (web/src/editor/DevelopInspector.jsx): push and bleach, grain, and the
// film's colour separation.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import 'controls.dart';

List<Widget> developPanel(InspectorControls c) {
  if (!c.hasFilm) {
    return const [
      Section(title: 'Normal', children: [
        Note('Choose a film from the library to use development and grain.'),
      ]),
    ];
  }
  const separation = [
    'couplers',
    'couplerReach',
    'couplerSelf',
    'chromaticFringeAmount',
    'chromaticFringeRadius',
  ];
  return [
    Section(title: 'Development', children: c.profileControls(const ['push', 'bleach'])),
    Section(title: 'Grain', children: [
      ...c.sliders('Character'),
      ...c.profileControls(const [
        'grainMottle',
        'grainModel',
        'filmGrainSize',
        'filmColourGrain',
        'filmRedLayer',
        'filmGreenLayer',
        'filmBlueLayer',
        'filmScanSoftness',
      ]),
      PillButton('New Grain Pattern', expand: true, onPressed: c.editor.newGrainPattern),
    ]),
    if (c.available.any(separation.take(4).contains))
      Section(title: 'Colour Separation', children: c.profileControls(separation)),
  ];
}
