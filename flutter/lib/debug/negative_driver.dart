// The driver's commands for scanned negatives (driver.dart):
//
//   {"openNegative": ["/path/scan.tif"]}   opens scans as negatives
//   {"trichromatic": ["/r.tif", ...]}       merges exposures and opens the scans
//   {"sampling": true}                      Pick Clear Film on or off
//   {"sampleFilmBase": [0.02, 0.5]}         samples clear film at a point of the picture (0–1)
//   {"showNegative": true}                  View › Show Negative
//   {"measureRoll": true}                   Measure Roll on the shown frame's roll
//   {"clearRoll": true}                     Balance Every Frame Alone
//   {"negative": {"crosstalk": 0.4}}        changes the shown negative's reading
//   {"select": 1}                           shows the strip's photograph at that index
import 'dart:ui' show Offset;

import '../model/editor.dart';

Future<void> driveNegatives(
    EditorModel editor, Map<String, dynamic> c, void Function(String) log) async {
  final scans = editor.negatives;
  if (c['openNegative'] case final List paths) {
    await scans.openNegatives(
        [for (final p in paths.cast<String>()) PhotoFile(p.split('/').last, path: p)]);
    log('negative ${editor.active?.negativeScan} tabs ${editor.inspectorTabs.map((p) => p.id)}');
  }
  if (c['trichromatic'] case final List paths) await scans.mergeExposures(paths.cast<String>());
  if (c['sampling'] case final bool on) scans.setSampling(on);
  if (c['sampleFilmBase'] case [final num x, final num y]) {
    scans.setSampling(true);
    await scans.sampleFilmBase(Offset(x.toDouble(), y.toDouble()));
    log('border ${scans.negative?['border']} error ${editor.error}');
  }
  if (c['showNegative'] case final bool on) {
    if (scans.showNegative != on) scans.toggleShowNegative();
    log('showNegative ${scans.showNegative} can ${scans.canShowNegativeNow}');
  }
  if (c['measureRoll'] == true) {
    await scans.measureRoll();
    log('roll ${scans.negative?['roll']} frames ${scans.rollFrames.length} error ${editor.error}');
  }
  if (c['clearRoll'] == true) scans.clearRoll();
  if (c['negative'] case final Map change) scans.read(change.cast());
  if (c['select'] case final int index) editor.selectDocument(index);
}
