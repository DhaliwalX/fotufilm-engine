// The Develop panel: push and bleach, grain, and the film's colour separation.
import 'package:flutter/widgets.dart';

import '../../model/phone_decks.dart' show filmGrainFields, separationFields;
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
  return [
    developmentSection(c),
    Section(title: 'Grain', children: [
      ...c.sliders('Character'),
      ...c.profileControls(const ['grainMottle', 'grainModel', ...filmGrainFields]),
      newGrainPatternButton(c),
    ]),
    ?colourSeparationSection(c),
  ];
}

Section developmentSection(InspectorControls c) =>
    Section(title: 'Development', children: c.profileControls(const ['push', 'bleach']));

/// How much grain, and its mottle.
List<Widget> grainControls(InspectorControls c) =>
    [...c.sliders('Character'), ...c.profileControls(const ['grainMottle'])];

List<Widget> grainModelControls(InspectorControls c) => c.profileControls(const ['grainModel']);

/// The film grain model's own layers, which only it has.
List<Widget> filmGrainControls(InspectorControls c) => c.profileControls(filmGrainFields);

Widget newGrainPatternButton(InspectorControls c) =>
    PillButton('New Grain Pattern', expand: true, onPressed: c.editor.newGrainPattern);

/// The couplers and fringes, for a film that has any.
Section? colourSeparationSection(InspectorControls c) =>
    c.available.any(separationFields.take(4).contains)
        ? Section(title: 'Colour Separation', children: c.profileControls(separationFields))
        : null;
