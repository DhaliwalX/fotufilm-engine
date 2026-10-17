// The film format, chosen by eye (web/src/editor/FormatPicker.jsx): a tile for each gauge with
// the photograph developed on it, whole or as a magnified detail.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/focus.dart';
import '../theme/theme.dart';
import '../workspace/picture.dart';

/// The format the photograph develops on: the chosen one, else the camera's frame where the
/// file records it, else the film's.
String? followedFormat(EditorModel editor) =>
    editor.edit['format'] as String? ??
    editor.active?.sensorGauge ??
    editor.selectedStock?['nativeFormat'] as String?;

class FormatPicker extends StatelessWidget {
  const FormatPicker({super.key, required this.editor});
  final EditorModel editor;

  static const _short = {
    'super8': 'Super 8',
    '16mm': '16 mm',
    'super35': 'Super 35',
    '35mm': '35 mm',
    '120': '120',
    '4x5': '4×5',
  };

  @override
  Widget build(BuildContext context) {
    final selected = followedFormat(editor);
    return LayoutBuilder(builder: (context, constraints) {
      const gap = Metrics.formatGap;
      final columns =
          ((constraints.maxWidth + gap) / (Metrics.formatTileMin + gap)).floor().clamp(1, 9);
      final tile = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final format in editor.catalogue.filmFormats)
          _FormatTile(
            width: tile,
            label: _short[format['id']] ?? format['name'] as String,
            picture: editor.active?.formatThumbnails[format['id'] as String],
            selected: format['id'] == selected,
            onTap: () => editor.change({'format': format['id']}),
          ),
      ]);
    });
  }
}

class _FormatTile extends StatelessWidget {
  const _FormatTile({
    required this.width,
    required this.label,
    required this.picture,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final String label;
  final ui.Image? picture;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return KeyTarget(
      onActivate: onTap,
      label: label,
      selected: selected,
      radius: 6,
      child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          boxShadow: selected ? [BoxShadow(color: palette.text, spreadRadius: 2)] : null,
          color: selected ? palette.panel : null,
        ),
        child: Column(children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x07000000),
                borderRadius: BorderRadius.circular(3),
              ),
              clipBehavior: Clip.antiAlias,
              child: picture == null ? null : EnginePicture(picture!, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: editorText(context, size: TextSizes.label)),
        ]),
      ),
      ),
    );
  }
}
