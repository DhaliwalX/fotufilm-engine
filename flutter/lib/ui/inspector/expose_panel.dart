// The Expose panel: light, the source illuminant, white balance, colour, the grade deck, then the
// film's long exposure, the filters on the lens, the lens, and an HDR photograph's highlights. A
// scanned negative printed on its film keeps only what acts on its print.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/negative_document.dart';
import '../kit/kit.dart';
import 'controls.dart';
import 'grade_deck.dart';
import 'lens_filters.dart';
import 'lens_section.dart';

final _gradeKeys = [
  for (final band in GradeDeck.bands)
    for (final axis in GradeDeck.axes) 'grade$band$axis',
];

List<Widget> exposePanel(InspectorControls c) {
  final editor = c.editor;
  final sceneLight = c.catalogue.control('sceneLight');
  final graded = _gradeKeys.any((k) => (c.params[k] as num? ?? 0) != 0);
  // A scanned negative's light acts on its print: nothing reaches a scene it never had.
  final negative = printsNegative(c.edit);
  // Only a photograph that records light above white has any to keep.
  final headroom = editor.active?.headroom ?? 1;
  return [
    Section(title: 'Light', children: [
      ...c.sliders('Light', film: !negative),
      if (!negative)
        SwitchRow(
          label: 'Regional',
          detail: c.catalogue.detail('localTone'),
          value: c.edit['localTone'] == true,
          onChanged: (v) => editor.change({'localTone': v}),
        ),
    ]),
    if (!negative) Section(title: 'Source Illuminant', children: [
      PickerField<String>(
        label: sceneLight['title'] as String,
        detail: sceneLight['detail'] as String?,
        value: c.edit['sceneLight'] as String,
        options: [
          for (final choice in (sceneLight['choices'] as List).cast<Json>())
            PickerOption(choice['id'] as String, choice['label'] as String),
        ],
        onChanged: (v) => editor.change({'sceneLight': v}),
      ),
      if (c.edit['sceneLight'] == 'custom') ...c.sliders('Source Illuminant'),
    ]),
    Section(title: 'White Balance', children: c.sliders('White Balance')),
    Section(title: 'Color', children: c.sliders('Color')),
    Section(title: 'Grade', children: [
      GradeDeck(editor: editor),
      c.editSwitch('gradeSpace', 'Encoded Grade'),
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton(
          'Reset Grade',
          variant: ButtonVariant.negative,
          onPressed: graded
              ? () => editor.change({
                    'params': {...c.params, for (final k in _gradeKeys) k: 0.0},
                  })
              : null,
        ),
      ),
    ]),
    if (!negative && c.available.contains('shutter'))
      Section(title: 'Long Exposure', children: c.profileControls(const ['shutter'])),
    if (!negative && !c.fixedSettings) lensFiltersSection(c),
    if (!negative) LensSection(editor: editor),
    if (!negative && headroom > 1)
      Section(title: 'HDR Highlights', children: [
        ...c.profileControls(const ['hdrRange', 'hdrRollOff']),
        Note('${_stops(math.log(headroom) / math.ln2)} stops above white recorded'),
      ]),
  ];
}

/// Stops to one decimal at most, as `Intl.NumberFormat` with `maximumFractionDigits: 1` writes.
String _stops(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}
