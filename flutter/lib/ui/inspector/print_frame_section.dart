// The Print panel's Frame: the frames this film and medium offer around the finished picture, and
// how a transparency's frame is viewed.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';

class PrintFrameSection extends StatelessWidget {
  const PrintFrameSection({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.printFrame,
        builder: (context, _) => _build(),
      );

  Widget _build() {
    final frames = editor.printFrame..follow();
    final control = editor.catalogue.control('printFrame');
    final value = editor.edit['printFrame'] as String? ?? 'none';
    final plan = frames.plan;
    final available = ((plan?['available'] as List?) ?? const []).cast<String>();
    final error = frames.error;
    final shown = (plan?['configuration'] as Map?)?['frame'];
    final renderMedium = plan?['renderMedium'] as String?;
    final edgePrinting = editor.catalogue.control('printFrameEdgePrinting');
    final frameNumber = editor.catalogue.control('printFrameNumber');
    final frameCount = editor.catalogue.control('printFrameCount');
    final camera = editor.catalogue.control('printFrameCamera');
    final printsEdge = editor.edit['printFrameEdgePrinting'] as bool? ?? true;
    return Section(title: 'Frame', children: [
      PickerField<String>(
        label: control['title'] as String,
        detail: control['detail'] as String?,
        value: value,
        enabled: !frames.pending && error == null,
        options: [
          for (final c in (control['choices'] as List).cast<Json>())
            if (c['id'] == value || available.contains(c['id']))
              PickerOption(c['id'] as String, c['label'] as String),
        ],
        onChanged: (frame) => editor.change({
          'printFrame': frame,
          // A film border or slide mount develops on Legacy halation, as the web editor's do.
          if (frame == 'film' || frame == 'slideMount') 'halationModel': 'legacy',
          // A film border shows a RAW as its sensor captured it (RAW Corrections).
          if (frame == 'film' || frame == 'filmPositive') 'rawCorrections': false,
        }),
      ),
      // The stock's edge printing on a film border, and the frame of the roll it is cut from.
      if (plan?['edgePrinting'] == true && (shown == 'film' || shown == 'filmPositive')) ...[
        SwitchRow(
          label: edgePrinting['title'] as String,
          detail: edgePrinting['detail'] as String?,
          value: printsEdge,
          enabled: !frames.pending,
          onChanged: (on) => editor.change({'printFrameEdgePrinting': on}),
        ),
        if (printsEdge && plan?['frameNumber'] == true)
          PickerField<int>(
            label: frameNumber['title'] as String,
            detail: frameNumber['detail'] as String?,
            value: (editor.edit['printFrameNumber'] as num? ?? 1).toInt(),
            enabled: !frames.pending,
            options: [
              for (final c in (frameNumber['choices'] as List).cast<Json>())
                PickerOption((c['value'] as num).toInt(), c['label'] as String),
            ],
            onChanged: (number) => editor.change({'printFrameNumber': number}),
          ),
      ],
      // A panorama across consecutive frames of the roll.
      if (plan?['spansFrames'] == true && (shown == 'film' || shown == 'filmPositive'))
        PickerField<int>(
          label: frameCount['title'] as String,
          detail: frameCount['detail'] as String?,
          value: (editor.edit['printFrameCount'] as num? ?? 1).toInt(),
          enabled: !frames.pending,
          options: [
            for (final c in (frameCount['choices'] as List).cast<Json>())
              PickerOption((c['value'] as num).toInt(), c['label'] as String),
          ],
          onChanged: (count) => editor.change({'printFrameCount': count}),
        ),
      // 135 in a 35mm or panoramic camera's gate, or across its width in a medium-format back.
      if (plan?['camera'] == true && (shown == 'film' || shown == 'filmPositive'))
        PickerField<String>(
          label: camera['title'] as String,
          detail: camera['detail'] as String?,
          value: editor.edit['printFrameCamera'] as String? ?? 'panoramic',
          enabled: !frames.pending,
          options: [
            for (final c in (camera['choices'] as List).cast<Json>())
              PickerOption(c['id'] as String, c['label'] as String),
          ],
          onChanged: (choice) => editor.change({'printFrameCamera': choice}),
        ),
      if (frames.framable) const Note('Drag the picture to choose the part the film shows.'),
      if (error != null || frames.pending) Note(error ?? 'Loading frame options…'),
      if (plan != null && shown != value) const Note('Shown once the film and medium support it.'),
      if (renderMedium != null)
        Note(switch (renderMedium) {
          'negative' => 'Viewed on a light box.',
          'lab-scan' => 'Photograph shown as a lab scan.',
          _ => 'Viewed by transmission.',
        }),
    ]);
  }
}
