// A scanned negative's Roll panel: what the frames of its roll share. The roll is the strip's
// negatives from the frame's folder; what they share is measured on all of them and kept with
// each, every frame still timed on its own highlights. Whether a frame is balanced on its roll
// is its Balance, with the light's white balance; an edit saved with an earlier reading is
// balanced on its roll while it keeps one.
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
  final current = scans.readsCurrent;
  return [
    Section(title: 'Roll', children: [
      InfoRow('Frames', frames.isEmpty ? 'Not in a folder' : '${frames.length}'),
    ]),
    Section(title: 'Colour Balance', children: [
      if (current)
        InfoRow('Measured on', roll != null ? '${roll['frames']} frames' : 'Not measured')
      else
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
      if (current)
        ScanButton('Clear Roll Measurement',
            onPressed: disabled || roll == null ? null : scans.clearRoll)
      else ...[
        ScanButton('Balance This Frame Alone',
            onPressed: disabled || roll == null ? null : scans.unrollFrame),
        ScanButton('Balance Every Frame Alone',
            onPressed: disabled || !enough ? null : scans.clearRoll),
      ],
      ScanHint(!enough
          ? 'Open a frame from a library folder of negatives: its roll is every negative in that '
              'folder.'
          : current
              ? 'Frames shot on one roll share the colour of its highlights and how steep its '
                  'colours read against each other. The steepness is used on every frame once '
                  'six frames show it. Set Balance to Roll, with the white balance, to balance a '
                  'frame on the roll\'s colour too. Each frame keeps its own exposure. Measure '
                  'again after cropping or adding frames.'
              : 'Frames shot on one roll under one light share the colour of the roll\'s '
                  'highlights. Each frame keeps its own exposure. Measure again after cropping '
                  'or adding frames.'),
    ]),
  ];
}
