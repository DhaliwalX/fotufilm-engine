// The Develop panel: push and bleach, grain, and the film's colour separation.
import 'package:flutter/widgets.dart';

import '../../app/strings.dart';
import '../kit/kit.dart';
import 'controls.dart';

List<Widget> developPanel(InspectorControls c) {
  if (!c.hasFilm) {
    return [
      Section(title: AppStrings.tr('Normal'), children: [
        Note(AppStrings.tr('Choose a film from the library to use development and grain.')),
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
    Section(title: AppStrings.tr('Development'), children: c.profileControls(const ['push', 'bleach'])),
    Section(title: AppStrings.tr('Grain'), children: [
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
      PillButton(AppStrings.tr('New Grain Pattern'), expand: true, onPressed: c.editor.newGrainPattern),
    ]),
    if (c.available.any(separation.take(4).contains))
      Section(title: AppStrings.tr('Colour Separation'), children: c.profileControls(separation)),
  ];
}
