// The Expose panel: light, the source illuminant, white balance, colour, the grade deck with the
// print's output levels, then the film's long exposure, the filters on the lens, the lens, and an
// HDR photograph's highlights. A scanned negative printed on its film keeps only what acts on its
// print.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/negative_document.dart';
import '../kit/kit.dart';
import 'controls.dart';
import 'grade_deck.dart';
import 'lens_filters.dart';
import 'lens_section.dart';
import 'negative_panel.dart';

final _gradeKeys = [
  for (final band in GradeDeck.bands)
    for (final axis in GradeDeck.axes) 'grade$band$axis',
];

/// The output levels and where each rests: Reset Grade returns them there too.
const _levelsAtRest = {'blackPoint': 0.0, 'whitePoint': 1.0};

List<Widget> exposePanel(InspectorControls c) {
  // A scanned negative's light acts on its print: nothing reaches a scene it never had.
  final negative = printsNegative(c.edit);
  return [
    lightSection(c),
    ?sourceIlluminantSection(c),
    whiteBalanceSection(c),
    colorSection(c),
    gradeSection(c),
    ?longExposureSection(c),
    if (!negative && !c.fixedSettings) lensFiltersSection(c),
    if (!negative) LensSection(editor: c.editor),
    ?hdrHighlightsSection(c),
  ];
}

Section lightSection(InspectorControls c) {
  final negative = printsNegative(c.edit);
  return Section(title: 'Light', children: [
    ...c.sliders('Light', film: !negative),
    if (!negative)
      SwitchRow(
        label: 'Regional',
        detail: c.catalogue.detail('localTone'),
        value: c.edit['localTone'] == true,
        onChanged: (v) => c.editor.change({'localTone': v}),
      ),
  ]);
}

/// The light the scene was lit by; a scanned negative had no scene to light.
Section? sourceIlluminantSection(InspectorControls c) {
  if (printsNegative(c.edit)) return null;
  final sceneLight = c.catalogue.control('sceneLight');
  return Section(title: 'Source Illuminant', children: [
    PickerField<String>(
      label: sceneLight['title'] as String,
      detail: sceneLight['detail'] as String?,
      value: c.edit['sceneLight'] as String,
      options: [
        for (final choice in (sceneLight['choices'] as List).cast<Json>())
          PickerOption(choice['id'] as String, choice['label'] as String),
      ],
      onChanged: (v) => c.editor.change({'sceneLight': v}),
    ),
    if (c.edit['sceneLight'] == 'custom') ...c.sliders('Source Illuminant'),
  ]);
}

/// The light's white balance, under what a scanned negative's frame is balanced on.
Section whiteBalanceSection(InspectorControls c) => Section(title: 'White Balance', children: [
      ...negativeBalanceControls(c),
      ...c.sliders('White Balance'),
    ]);

Section colorSection(InspectorControls c) => Section(title: 'Color', children: c.sliders('Color'));

/// The grade deck with the print's output levels, and Reset Grade.
Section gradeSection(InspectorControls c) {
  final editor = c.editor;
  final graded = _gradeKeys.any((k) => (c.params[k] as num? ?? 0) != 0) ||
      _levelsAtRest.entries.any((e) => (c.params[e.key] as num? ?? e.value) != e.value);
  return Section(title: 'Grade', children: [
    GradeDeck(editor: editor),
    ...c.sliders('Output Levels'),
    c.editSwitch('gradeSpace', 'Encoded Grade'),
    Align(
      alignment: Alignment.centerLeft,
      child: PillButton(
        'Reset Grade',
        variant: ButtonVariant.negative,
        onPressed: graded
            ? () => editor.change({
                  'params': {...c.params, for (final k in _gradeKeys) k: 0.0, ..._levelsAtRest},
                })
            : null,
      ),
    ),
  ]);
}

/// The film's long exposure, for a film that has one.
Section? longExposureSection(InspectorControls c) =>
    !printsNegative(c.edit) && c.available.contains('shutter')
        ? Section(title: 'Long Exposure', children: c.profileControls(const ['shutter']))
        : null;

/// Only a photograph that records light above white has any to keep.
Section? hdrHighlightsSection(InspectorControls c) {
  final headroom = c.editor.active?.headroom ?? 1;
  if (printsNegative(c.edit) || headroom <= 1) return null;
  return Section(title: 'HDR Highlights', children: [
    ...c.profileControls(const ['hdrRange', 'hdrRollOff']),
    Note('${_stops(math.log(headroom) / math.ln2)} stops above white recorded'),
  ]);
}

/// Stops to one decimal at most, as `Intl.NumberFormat` with `maximumFractionDigits: 1` writes.
String _stops(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}
