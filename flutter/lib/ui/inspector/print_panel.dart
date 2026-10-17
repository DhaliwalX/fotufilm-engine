// The Print panel (web/src/editor/PrintInspector.jsx): the output medium, the screen conversion
// or the print's controls, and the enlarger's lamp.
import 'package:flutter/widgets.dart';

import '../../model/catalogue.dart';
import '../kit/kit.dart';
import 'controls.dart';

const _matchFilm = 'match-film';
const _screenCMY = ['screenCyan', 'screenMagenta', 'screenYellow'];

List<Widget> printPanel(InspectorControls c) {
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
  final cmyChanged = _screenCMY.any((f) => (c.profile[f] as num? ?? 0) != 0);
  return [
    Section(title: 'Output', children: [
      PickerField<String>(
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
      ...c.profileControls(const [
        'printLight',
        'printCorrection',
        'printerRed',
        'printerGreen',
        'printerBlue',
        'negativeViewing',
        'screenGrade',
        'screenExposure',
        ..._screenCMY,
        'labScanLook',
        'labScanDodging',
      ]),
      if (printMedium?['screenCMY'] == true)
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            'Reset CMY',
            onPressed: cmyChanged
                ? () => editor.change({
                      'profile': Map.of(c.profile)..removeWhere((k, _) => _screenCMY.contains(k)),
                    })
                : null,
          ),
        ),
      const InfoRow('Color space', 'Display P3 → sRGB'),
    ]),
    if (printMedium?['enlarger'] == true)
      Section(
        title: 'Lamp',
        children: c.profileControls(const [
          'enlarger',
          'printerEnabled',
          'printerLamp',
          'printerExposure',
          'printerMagenta',
          'printerYellow',
          'printerPreflash',
        ]),
      ),
  ];
}
