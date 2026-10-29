// The Film panel: the loaded film, its format chosen by eye, its condition and its halation. A film
// with a fixed profile has none of its settings.
import 'package:flutter/widgets.dart';

import '../../app/strings.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import 'controls.dart';
import 'format_picker.dart';

/// A chosen format goes back to the camera's or the film's; otherwise which one is followed.
List<Widget> _following(EditorModel editor) {
  final camera = editor.active?.sensorGauge != null;
  if (editor.edit['format'] != null) {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton(camera ? AppStrings.tr('Match the Camera') : AppStrings.tr('Match the Film'),
            onPressed: () => editor.change({'format': null})),
      ),
    ];
  }
  if (!camera) return [Note(AppStrings.tr('Following the film.'))];
  final followed = followedFormat(editor);
  final name = editor.catalogue.filmFormats
      .where((f) => f['id'] == followed)
      .map((f) => f['name'] as String)
      .firstOrNull;
  return [Note('${AppStrings.tr('Following the camera:')} ${name ?? followed}.')];
}

List<Widget> filmPanel(InspectorControls c) {
  final editor = c.editor;
  if (!c.hasFilm) {
    return [
      Section(title: AppStrings.tr('Normal'), children: [InfoRow(AppStrings.tr('Stock'), AppStrings.tr('None'))]),
    ];
  }
  final fixed = c.fixedSettings;
  return [
    Section(title: AppStrings.tr('Loaded Film'), children: [
      if (fixed) Note(AppStrings.tr('Fixed profile: film settings are off.')),
      InfoRow(AppStrings.tr('Stock'), c.stock?['name'] as String? ?? ''),
    ]),
    if (!fixed) Section(title: AppStrings.tr('Film Format'), children: [
      FormatPicker(editor: editor),
      SwitchRow(
        label: AppStrings.tr('Magnified Detail'),
        value: editor.formatDetail,
        onChanged: editor.setFormatDetail,
      ),
      ..._following(editor),
    ]),
    if (!fixed) Section(title: AppStrings.tr('Film Condition'), children: c.profileControls(const ['expired'])),
    Section(title: AppStrings.tr('Halation'), children: [
      PickerField<String>(
        label: AppStrings.tr('Halation Model'),
        detail: c.catalogue.detail('halationModel'),
        value: c.edit['halationModel'] as String? ?? 'legacy',
        options: [
          PickerOption('legacy', AppStrings.tr('Legacy')),
          PickerOption('layered', AppStrings.tr('Layered Transport')),
        ],
        onChanged: (v) => editor.change({'halationModel': v}),
      ),
      ...c.profileControls(const [
        'halation',
        'halationReturn',
        'halationColour',
        'halationSpectrum',
        'halationHaze',
        'antiHalation',
        'baseThickness',
        'pressurePlate',
        'estimatedHalation',
      ]),
    ]),
  ];
}
