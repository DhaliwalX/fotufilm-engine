// A scanned negative's Film panel: what the scan is read as. The film is chosen in the film
// library; here are the films its base looks like, the clear film it is measured against, what
// the scan was made with and under (Scan Setup), and what the reading takes back out of it (Scan
// Correction): the dyes' crosstalk and the scan's stray light. An edit saved with an earlier
// reading keeps that reading's controls until it is updated. The print is the Print panel's, and
// what the frame is balanced on is with the light's white balance.
import 'package:flutter/widgets.dart';

import '../../model/negatives.dart';
import '../kit/kit.dart';
import 'controls.dart';
import 'scan_controls.dart';

// The lights a scan can be made under (NegativeScanCrosstalk.Light), and the two an earlier
// reading told apart.
const _scanLights = [
  PickerOption('white', 'White LED Panel'),
  PickerOption('screen', 'Phone or Tablet Screen'),
  PickerOption('halogen', 'Halogen Lamp'),
  PickerOption('rgb', 'Red, Green and Blue LEDs'),
];
const _firstScanLights = [
  PickerOption('white', 'White Light'),
  PickerOption('rgb', 'Red, Green and Blue LEDs'),
];

const _scannedWithDetail =
    'What took the scan. Auto reads a camera RAW through its own camera\'s measured colour '
    'channels where the camera is one of those measured, and any other file as a generic '
    'camera. Choose Film Scanner for a scan from a dedicated film scanner.';

const _scannedUnderDetail =
    'The light behind the film. A phone or tablet screen and separate red, green and blue LEDs '
    'light the film in narrower bands than a white panel or a halogen lamp, which changes how '
    'much of each dye every channel sees.';

const _separationDetail =
    'A camera or scanner channel sees a little of every dye, not just its own, which mutes the '
    'colours of a scanned negative. The reading separates them from what the film\'s dyes, the '
    'light and the camera are known to be. Lower it to read each dye more from its own channel '
    'alone.';

const _flareDetail =
    'Stray light in the scan, from the lens and the room, as a share of the frame\'s average '
    'light. It lifts every sample alike, which reads the densest highlights thinner than they '
    'are. Left to measure, it is read from the holder where the scan shows one, and is none '
    'otherwise.';

const _balanceDetail =
    'What the frame\'s colour is balanced on. Frame uses the frame\'s own highlights, or a '
    'neutral picked on it. Roll uses what the roll\'s frames share, measured in the Roll panel, '
    'so a frame filled by one colour keeps it. None leaves the film as it reads: a scene under '
    'warm light stays warm.';

// How far a negative's reading undoes the crosstalk between the scan's channels and the film's
// dyes (NegativeScanCrosstalk): 0 reads each dye from its own channel alone.
const _crosstalkDetail =
    'A camera or scanner channel sees a little of every dye, not just its own, which mutes the '
    'colours of a scanned negative. Raise it to separate them again. Greys stay grey: the '
    'frame\'s highlights read as before. Set the light the scan was made under first: separate '
    'red, green and blue LED exposures have little crosstalk to undo.';

List<Widget> negativePanel(InspectorControls c) {
  if (c.editor.negatives.negative == null) return const [];
  return [
    negativeFilmSection(c),
    filmBaseSection(c),
    if (c.editor.negatives.readsCurrent) ...[
      scanSetupSection(c),
      scanCorrectionSection(c),
    ] else ...[
      scanColourSection(c),
      ?lightSourceSection(c),
      ?updateReadingSection(c),
    ],
  ];
}

/// The film the scan is read as, and the films its base looks like.
Section negativeFilmSection(InspectorControls c) {
  final editor = c.editor;
  final suggestions = editor.negatives.suggestions;
  return Section(title: 'Negative', children: [
    InfoRow('Film', c.stock?['name'] as String? ?? 'Normal'),
    if (suggestions.isNotEmpty) const InfoRow('Base looks like', ''),
    for (final s in suggestions)
      ScanButton(
        suggestionName(s),
        quiet: true,
        onPressed: c.edit['stock'] == ((s['films'] as List).first as Map)['id']
            ? null
            : () => editor.chooseStock(((s['films'] as List).first as Map)['id'] as String),
      ),
  ]);
}

/// The clear film the scan is measured against.
Section filmBaseSection(InspectorControls c) {
  final scans = c.editor.negatives;
  final negative = scans.negative ?? const {};
  return Section(title: 'Film Base', children: [
    InfoRow('Clear film', negative['border'] != null ? 'Sampled' : 'Estimated'),
    ScanButton(
      'Pick Clear Film',
      selected: scans.picking == 'border',
      onPressed: () => scans.setSampling(scans.picking != 'border'),
    ),
    ScanButton(
      'Estimate',
      onPressed: negative['border'] == null ? null : () => scans.read({'border': null}),
    ),
  ]);
}

/// What the scan was made with and under, and the light frame that evens its light out, which
/// a layout with a page of its own for the light source leaves there.
Section scanSetupSection(InspectorControls c, {bool lightFrames = true}) {
  final scans = c.editor.negatives;
  final negative = scans.negative ?? const {};
  final found = scans.scannedWithName;
  return Section(title: 'Scan Setup', children: [
    PickerField<String?>(
      label: 'Scanned With',
      detail: _scannedWithDetail,
      value: negative['camera'] as String?,
      options: [
        PickerOption(null, found == null ? 'Auto' : 'Auto ($found)'),
        const PickerOption('generic', 'Generic Camera'),
        const PickerOption('scanner', 'Film Scanner'),
      ],
      onChanged: (v) => scans.read({'camera': v}),
    ),
    PickerField<String>(
      label: 'Scanned Under',
      detail: _scannedUnderDetail,
      value: negative['scanLight'] as String? ?? 'white',
      options: _scanLights,
      onChanged: (v) => scans.read({'scanLight': v}),
    ),
    if (lightFrames) ..._lightFrameControls(c),
  ]);
}

/// What the reading takes back out of the scan: the dyes' crosstalk and its stray light.
Section scanCorrectionSection(InspectorControls c) {
  final scans = c.editor.negatives;
  final negative = scans.negative ?? const {};
  final flare = negative['flare'] as num?;
  return Section(title: 'Scan Correction', children: [
    AdjustmentRow(
      label: 'Colour Separation',
      detail: _separationDetail,
      value: (negative['crosstalk'] as num? ?? 1).toDouble(),
      range: const SliderRange(min: 0, max: 1, step: .01, def: 1),
      onChanged: scans.setCrosstalk,
      onEnd: c.editor.endEdit,
    ),
    SwitchRow(
      label: 'Measure Flare',
      detail: _flareDetail,
      value: flare == null,
      onChanged: (measured) => scans.read({'flare': measured ? null : 0.0}),
    ),
    if (flare != null)
      AdjustmentRow(
        label: 'Flare',
        detail: _flareDetail,
        value: flare.toDouble(),
        range: const SliderRange(min: 0, max: .02, step: .0005, def: 0),
        unit: '%',
        readoutScale: 100,
        onChanged: scans.setFlare,
        onEnd: c.editor.endEdit,
      ),
  ]);
}

/// What the frame is balanced on and a neutral picked on it, above the light's white balance:
/// only a negative read with the current reading has them.
List<Widget> negativeBalanceControls(InspectorControls c) {
  final scans = c.editor.negatives;
  final negative = scans.negative;
  if (negative == null || !scans.readsCurrent) return const [];
  final balance = balanceOf(negative);
  final picked = negative['neutral'] != null;
  return [
    PickerField<String>(
      label: 'Balance',
      detail: _balanceDetail,
      value: balance,
      options: const [
        PickerOption('frame', 'Frame'),
        PickerOption('roll', 'Roll'),
        PickerOption('none', 'None'),
      ],
      onChanged: (v) => scans.read({'balance': v}),
    ),
    if (balance == 'roll' && negative['roll'] == null)
      const ScanHint('This roll is not measured yet, so the frame is balanced on its own. '
          'Measure it in the Roll panel.'),
    if (balance != 'none') ...[
      ScanButton(
        'Pick Neutral',
        selected: scans.picking == 'neutral',
        onPressed: () => scans.setPicking(scans.picking == 'neutral' ? null : 'neutral'),
      ),
      ScanButton(
        'Clear Picked Neutral',
        onPressed: picked ? () => scans.read({'neutral': null}) : null,
      ),
    ],
  ];
}

/// Update Reading, for an edit saved with an earlier reading than the engine's.
Section? updateReadingSection(InspectorControls c) {
  final scans = c.editor.negatives;
  if (!scans.canUpdateReading) return null;
  return Section(title: 'Reading', children: [
    ScanButton('Update Reading', onPressed: scans.updateReading),
    const ScanHint('This negative was saved with an earlier reading of its scan and prints as it '
        'did. Update it to read the film through the scan\'s light and camera: its colours will '
        'change, and Undo brings them back.'),
  ]);
}

/// An earlier reading's light and how far the dyes' crosstalk is undone.
Section scanColourSection(InspectorControls c) {
  final scans = c.editor.negatives;
  final negative = scans.negative ?? const {};
  return Section(title: 'Colour Separation', children: [
    PickerField<String>(
      label: 'Scanned Under',
      value: negative['scanLight'] as String? ?? 'white',
      options: _firstScanLights,
      onChanged: (v) => scans.read({'scanLight': v}),
    ),
    AdjustmentRow(
      label: 'Crosstalk Correction',
      detail: _crosstalkDetail,
      value: (negative['crosstalk'] as num? ?? 0).toDouble(),
      range: const SliderRange(min: 0, max: 1, step: .01, def: 0),
      onChanged: scans.setCrosstalk,
      onEnd: c.editor.endEdit,
    ),
  ]);
}

/// The light frame that evens out the scan's light. Light frames are kept by a host with a file
/// system, not by a browser.
Section? lightSourceSection(InspectorControls c) {
  final controls = _lightFrameControls(c);
  return controls.isEmpty ? null : Section(title: 'Light Source', children: controls);
}

List<Widget> _lightFrameControls(InspectorControls c) {
  final scans = c.editor.negatives;
  if (!scans.keepsLightFrames) return const [];
  final lightFrame = scans.negative?['lightFrame'] as String?;
  final frames = scans.lightFrames;
  return [
    PickerField<String?>(
      label: scans.readsCurrent ? 'Light Frame' : null,
      value: frames.any((f) => f['id'] == lightFrame) ? lightFrame : null,
      options: [
        const PickerOption(null, 'As Scanned'),
        for (final f in frames) PickerOption(f['id'] as String, f['name'] as String),
      ],
      onChanged: (id) => scans.read({'lightFrame': id}),
    ),
    ScanButton('Add Light Frame…', onPressed: scans.chooseLightFrame),
    ScanButton('Remove Light Frame',
        onPressed: lightFrame == null ? null : scans.removeLightFrame),
  ];
}
