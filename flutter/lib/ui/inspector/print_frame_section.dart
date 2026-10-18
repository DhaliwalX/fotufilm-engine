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
        }),
      ),
      if (error != null || frames.pending) Note(error ?? 'Loading frame options…'),
      if (plan != null && shown != value) const Note('Shown once the film and medium support it.'),
      if (renderMedium != null)
        Note(renderMedium == 'negative' ? 'Viewed on a light box.' : 'Viewed by transmission.'),
    ]);
  }
}
