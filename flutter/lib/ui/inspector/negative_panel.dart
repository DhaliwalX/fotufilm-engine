// A scanned negative's Film panel: what the scan is read as. The film is chosen in the film
// library; here are the films its base looks like, the clear film it is measured against, how far
// its dyes' crosstalk is undone, the light it was scanned under and the light frame that evens it
// out. The print is the Print panel's.
import 'package:flutter/widgets.dart';

import '../../model/negatives.dart';
import '../kit/kit.dart';
import 'controls.dart';
import 'scan_controls.dart';

// The lights a scan can be made under (NegativeScanCrosstalk.Light).
const _scanLights = [
  PickerOption('white', 'White Light'),
  PickerOption('rgb', 'Red, Green and Blue LEDs'),
];

// How far a negative's reading undoes the crosstalk between the scan's channels and the film's
// dyes (NegativeScanCrosstalk): 0 reads each dye from its own channel alone.
const _crosstalkDetail =
    'A camera or scanner channel sees a little of every dye, not just its own, which mutes the '
    'colours of a scanned negative. Raise it to separate them again. Greys stay grey: the '
    'frame\'s highlights read as before. Set the light the scan was made under first: separate '
    'red, green and blue LED exposures have little crosstalk to undo.';

List<Widget> negativePanel(InspectorControls c) {
  final editor = c.editor;
  final scans = editor.negatives;
  final negative = scans.negative;
  if (negative == null) return const [];
  final suggestions = scans.suggestions;
  final lightFrame = negative['lightFrame'] as String?;
  final frames = scans.lightFrames;
  return [
    Section(title: 'Negative', children: [
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
    ]),
    Section(title: 'Film Base', children: [
      InfoRow('Clear film', negative['border'] != null ? 'Sampled' : 'Estimated'),
      ScanButton(
        'Pick Clear Film',
        selected: scans.sampling,
        onPressed: () => scans.setSampling(!scans.sampling),
      ),
      ScanButton(
        'Estimate',
        onPressed: negative['border'] == null ? null : () => scans.read({'border': null}),
      ),
    ]),
    Section(title: 'Colour Separation', children: [
      PickerField<String>(
        label: 'Scanned Under',
        value: negative['scanLight'] as String? ?? 'white',
        options: _scanLights,
        onChanged: (v) => scans.read({'scanLight': v}),
      ),
      AdjustmentRow(
        label: 'Crosstalk Correction',
        detail: _crosstalkDetail,
        value: (negative['crosstalk'] as num? ?? 0).toDouble(),
        range: const SliderRange(min: 0, max: 1, step: .01, def: 0),
        onChanged: scans.setCrosstalk,
        onEnd: editor.endEdit,
      ),
    ]),
    // Light frames are kept by a host with a file system, not by a browser.
    if (scans.keepsLightFrames)
      Section(title: 'Light Source', children: [
        PickerField<String?>(
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
      ]),
  ];
}
