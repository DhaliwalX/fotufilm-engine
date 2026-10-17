// The Film panel (web/src/editor/FilmInspector.jsx): the loaded film, its format chosen by eye,
// its condition and its halation.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import 'controls.dart';
import 'format_picker.dart';

List<Widget> filmPanel(InspectorControls c) {
  final editor = c.editor;
  if (!c.hasFilm) {
    return const [
      Section(title: 'Normal', children: [InfoRow('Stock', 'None')]),
    ];
  }
  return [
    Section(title: 'Loaded Film', children: [
      InfoRow('Stock', c.stock?['name'] as String? ?? ''),
    ]),
    Section(title: 'Film Format', children: [
      FormatPicker(editor: editor),
      SwitchRow(
        label: 'Magnified Detail',
        value: editor.formatDetail,
        onChanged: editor.setFormatDetail,
      ),
      Note(c.edit['format'] == null ? 'Following the film.' : 'Chosen for this photograph.'),
    ]),
    Section(title: 'Film Condition', children: c.profileControls(const ['expired'])),
    Section(title: 'Halation', children: [
      PickerField<String>(
        label: 'Halation Model',
        detail: c.catalogue.detail('halationModel'),
        value: c.edit['halationModel'] as String? ?? 'legacy',
        options: const [
          PickerOption('legacy', 'Legacy'),
          PickerOption('layered', 'Layered Transport'),
        ],
        onChanged: (v) => editor.change({'halationModel': v}),
      ),
      ...c.profileControls(const [
        'halation',
        'halationReturn',
        'halationColour',
        'halationHaze',
        'antiHalation',
        'baseThickness',
        'pressurePlate',
      ]),
    ]),
  ];
}
