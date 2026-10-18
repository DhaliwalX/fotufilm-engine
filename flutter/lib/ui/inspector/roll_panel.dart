// A scanned negative's Roll panel (web/src/editor/RollInspector.jsx): what the frames of its roll
// share. The roll is the strip's negatives from the frame's folder; its colour balance is measured
// on all of them and kept with each, every frame still timed on its own highlights.
import 'package:flutter/widgets.dart';

import '../kit/kit.dart';
import 'controls.dart';
import 'scan_controls.dart';

List<Widget> rollPanel(InspectorControls c) {
  final scans = c.editor.negatives;
  final negative = scans.negative;
  if (negative == null) return const [];
  final roll = negative['roll'] as Map?;
  final frames = scans.rollFrames;
  final measuring = scans.measuring;
  final disabled = measuring != null;
  final enough = frames.length >= 2;
  return [
    Section(title: 'Roll', children: [
      InfoRow('Frames', frames.isEmpty ? 'Not in a folder' : '${frames.length}'),
    ]),
    Section(title: 'Colour Balance', children: [
      InfoRow('Balanced on', roll != null ? 'Roll of ${roll['frames']} frames' : 'This frame'),
      if (measuring != null) ...[
        ScanProgress(
          label: 'Measuring frame ${(measuring.done + 1).clamp(1, measuring.total)} of '
              '${measuring.total}',
          value: measuring.done / measuring.total,
        ),
        ScanButton('Cancel', onPressed: scans.cancelMeasure),
      ] else
        ScanButton(roll != null ? 'Measure Roll Again' : 'Measure Roll',
            onPressed: disabled || !enough ? null : scans.measureRoll),
      ScanButton('Balance This Frame Alone',
          onPressed: disabled || roll == null ? null : scans.unrollFrame),
      ScanButton('Balance Every Frame Alone',
          onPressed: disabled || !enough ? null : scans.clearRoll),
      ScanHint(enough
          ? 'Frames shot on one roll under one light share the colour of the roll\'s highlights. '
              'Each frame keeps its own exposure. Measure again after cropping or adding frames.'
          : 'Open a frame from a library folder of negatives: its roll is every negative in that '
              'folder.'),
    ]),
  ];
}
