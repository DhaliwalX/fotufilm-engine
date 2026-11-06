// The Print panel: the output medium and its receiver bands, the screen conversion or the print's
// controls, the enlarger's lamp, the frame, and export.
import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../../model/phone_decks.dart' show printAdjustFields;
import '../../model/video.dart' show MovieDocument;
import '../kit/kit.dart';
import '../workspace/export_dialog.dart';
import 'controls.dart';
import 'print_frame_section.dart';
import 'receiver_bands.dart';

const _matchFilm = 'match-film';
const _screenCMY = ['screenCyan', 'screenMagenta', 'screenYellow'];

List<Widget> printPanel(InspectorControls c) {
  final editor = c.editor;
  return [
    Section(title: 'Output', children: [
      ...printOutputControls(c),
      ...printAdjustControls(c),
      // The engine develops in Display P3, the space the web editor's canvas shows in the app.
      const InfoRow('Color space', 'Display P3'),
    ]),
    ?lampSection(c),
    if (!c.fixedSettings && editor.active != null) PrintFrameSection(editor: editor),
    Section(title: 'Export', children: [
      Builder(
        builder: (context) => Align(
          alignment: Alignment.centerLeft,
          child: PillButton(editor.active?.isMovie == true ? 'Export Video…' : 'Export Photo…',
              onPressed: () => showExportDialog(context, editor)),
        ),
      ),
    ]),
  ];
}

/// The output medium with its receiver bands, and the screen conversion.
List<Widget> printOutputControls(InspectorControls c) {
  final editor = c.editor;
  final stock = c.stock;
  final canMatchFilm = stock?['filmMedium'] != null && stock?['reflectionPrint'] != true;
  final media = ((stock?['media'] as List?) ??
          const [
            {'id': 'screen', 'name': 'Digital Reference'},
          ])
      .cast<Map>();
  final medium = (c.edit['medium'] ?? stock?['defaultMedium'] ?? 'screen') as String;
  final screen = media.where((m) => m['id'] == 'screen').firstOrNull;
  final conversion = c.catalogue.screenConversion;
  final printMedium = Catalogue.profileMedium(c.edit, stock);
  return [
    MediumRow(
      editor: editor,
      offersBands: !c.fixedSettings && printMedium?['receiverBands'] == true,
      picker: PickerField<String>(
        label: 'Output medium',
        enabled: c.hasFilm,
        value: c.edit['mediumFollowsFilm'] == true && canMatchFilm ? _matchFilm : medium,
        options: [
          if (canMatchFilm) const PickerOption(_matchFilm, 'Match Film'),
          for (final m in media) PickerOption(m['id'] as String, m['name'] as String),
        ],
        onChanged: (choice) => editor.change(choice == _matchFilm
            ? {'medium': stock!['filmMedium'], 'mediumFollowsFilm': true}
            : {'medium': choice, 'mediumFollowsFilm': false}),
      ),
    ),
    if (medium == 'screen' && screen?['screenConversions'] != null)
      PickerField<String>(
        label: conversion['title'] as String,
        detail: c.catalogue.detail('digitalReference'),
        value: c.edit['digitalReference'] as String? ?? conversion['default'] as String,
        options: [
          for (final choice in (conversion['choices'] as List).cast<Json>())
            PickerOption(choice['id'] as String, choice['name'] as String),
        ],
        onChanged: (v) => editor.change({'digitalReference': v}),
      ),
  ];
}

/// The print's or the screen conversion's own controls, with Reset CMY.
List<Widget> printAdjustControls(InspectorControls c) {
  final printMedium = Catalogue.profileMedium(c.edit, c.stock);
  final cmyChanged = _screenCMY.any((f) => (c.profile[f] as num? ?? 0) != 0);
  return [
    ...c.profileControls(printAdjustFields),
    if (!c.fixedSettings && printMedium?['screenCMY'] == true)
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton(
          'Reset CMY',
          onPressed: cmyChanged
              ? () => c.editor.change({
                    'profile': Map.of(c.profile)..removeWhere((k, _) => _screenCMY.contains(k)),
                  })
              : null,
        ),
      ),
  ];
}

/// The enlarger's lamp, for a medium printed under one.
Section? lampSection(InspectorControls c) =>
    Catalogue.profileMedium(c.edit, c.stock)?['enlarger'] == true
        ? Section(
            title: 'Lamp',
            // The enlarger's lamp is set once in a while; it starts folded away below the output.
            initiallyOpen: false,
            children: c.profileControls(const [
              'enlarger',
              'printerEnabled',
              'printerLamp',
              'printerExposure',
              'printerMagenta',
              'printerYellow',
              'printerPreflash',
            ]),
          )
        : null;
