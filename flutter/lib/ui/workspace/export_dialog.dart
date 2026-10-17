// The Export dialog (web/src/editor/ExportDialog.jsx, styles/dialogs.css): this photograph or
// all of them, the format (or the original RAW), the size the engine can develop, quality,
// metadata and HDR, what the file will be, and Cancel that stops an export in flight.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/export.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'dialogs.dart';

void showExportDialog(BuildContext context, EditorModel editor) =>
    showModal(context, (close) => ExportDialog(editor: editor, onClose: close));

class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key, required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  EditorModel get editor => widget.editor;
  ExportTool get exporter => editor.exporter;

  /// This Photo or All N Photos; each opening starts on the photo, as React's does.
  String _scope = 'photo';

  @override
  void initState() {
    super.initState();
    exporter.loadOptions();
  }

  Future<void> _export(bool batch) async {
    final saved = batch ? await exporter.exportAll() : await exporter.exportPhoto();
    if (saved != null && mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: editor, builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final doc = editor.active;
    if (doc == null) return const SizedBox.shrink();
    final x = exporter;
    final exporting = editor.exporting;
    final count = x.batchCount;
    final batch = count > 1 && _scope == 'all';
    final originalAvailable = !batch && x.originalAvailable(doc);
    // A photograph with no camera RAW behind it has no original to export.
    if (x.type == originalType && !originalAvailable) x.type = x.types.first.$1;
    final original = x.type == originalType;
    final sizes = x.sizes(batch: batch);
    final unavailable = x.unavailable(batch: batch);
    // The largest size it can develop stands in for one it cannot, as the Mac app selects.
    final sizeId = x.sizeId(batch: batch);
    if (x.size != sizeId) x.size = sizeId;
    final warning = resolutionLimitWarning(sizes, sizeId, unavailable);
    final hdrOffered = batch ? x.batchHDR : x.options?.hdr == true;
    final hdr = x.type == 'image/heic' && hdrOffered && x.hdr;
    final last = x.last;
    final delivered = x.delivered(doc);
    final metadata = x.options?.metadata;
    final palette = Palette.of(context);

    return DialogCard(
      title: batch ? 'Export $count photos' : 'Export image',
      width: 480,
      actions: [
        PillButton('Cancel', onPressed: exporting ? x.cancel : widget.onClose),
        PillButton(
          exporting
              ? 'Exporting…'
              : original
                  ? 'Export Original'
                  : batch
                      ? 'Export $count Photos'
                      : 'Export',
          variant: ButtonVariant.accent,
          onPressed: exporting || (!original && unavailable.contains(sizeId))
              ? null
              : () => _export(batch),
        ),
      ],
      children: [
        // The fieldset: nothing changes while an export runs.
        IgnorePointer(
          ignoring: exporting,
          child: Opacity(
            opacity: exporting ? .45 : 1,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (count > 1)
                _SelectRow('Export', PickerField<String>(
                  value: _scope,
                  options: [
                    const PickerOption('photo', 'This Photo'),
                    PickerOption('all', 'All $count Photos'),
                  ],
                  onChanged: (v) => setState(() => _scope = v),
                )),
              if (last != null && !_same(last, x.current))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  // In a row, so the button keeps its own width.
                  child: Row(children: [
                    PillButton('Use Last Export Settings', onPressed: x.applyLast),
                  ]),
                ),
              _SelectRow('Format', PickerField<String>(
                value: x.type,
                options: [
                  for (final (id, label) in x.types) PickerOption(id, label),
                  if (originalAvailable) const PickerOption(originalType, 'Original RAW'),
                ],
                onChanged: (v) => setState(() => x.type = v),
              )),
              if (original)
                const _Detail('Copies the original camera RAW file. Fotufilm edits and the '
                    'resolution setting are not included.')
              else ...[
                _SelectRow('Size', PickerField<String>(
                  value: sizeId,
                  options: [
                    for (final s in sizes)
                      PickerOption(
                        s.id,
                        [s.label, ?s.detail, if (unavailable.contains(s.id)) 'Exceeds safe memory limit']
                            .join(' · '),
                        enabled: !unavailable.contains(s.id),
                      ),
                  ],
                  onChanged: (v) => setState(() => x.size = v),
                )),
                if (warning != null) _Detail(warning),
                if (lossyTypes.contains(x.type))
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: AdjustmentRow(
                      label: 'Quality',
                      value: x.quality.toDouble(),
                      range: const SliderRange(min: 1, max: 100, step: 1, def: 95),
                      onChanged: (v) => setState(() => x.quality = v.round()),
                    ),
                  ),
                if (metadata != null)
                  _SelectRow('Metadata', PickerField<String>(
                    value: x.metadata,
                    options: [
                      for (final id in metadata) PickerOption(id, metadataLabels[id] ?? id),
                    ],
                    onChanged: (v) => setState(() => x.metadata = v),
                  )),
                if (x.type == 'image/heic' && hdrOffered)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: SwitchRow(label: 'HDR', value: x.hdr, onChanged: (v) => x.hdr = v),
                  ),
                // The desktop engine writes Display P3 (backend/desktop/host.js
                // `outputColorSpace`).
                _Detail('${batch ? '$count photos' : '${delivered.width} × ${delivered.height} '
                    'pixels'} · Display P3 · '
                    '${x.type == 'image/tiff' ? '16-bit' : hdr ? 'HDR' : '8-bit'}'),
                _Detail(batch
                    ? 'Exports every photo with its own film, crop and adjustments into one '
                        'folder.'
                    : 'Exports the finished image with the current crop and adjustments.'),
              ],
            ]),
          ),
        ),
        if (exporting)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(editor.status ?? 'Preparing export',
                style: editorText(context, color: palette.text)),
          ),
      ],
    );
  }

  /// The last settings equal the dialog's, as React compares them.
  static bool _same(Json a, Json b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// A name on the left and its picker on the right (`[role=dialog] .select-row`).
class _SelectRow extends StatelessWidget {
  const _SelectRow(this.label, this.control);
  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          SizedBox(width: 260, child: control),
        ]),
      );
}

/// A muted line under the controls (`.export-detail`).
class _Detail extends StatelessWidget {
  const _Detail(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(text,
            style: editorText(context,
                size: TextSizes.label, color: Palette.of(context).muted, height: 1.6)),
      );
}
