// The workspace's dialogs: Export (web/src/editor/ExportDialog.jsx, styles/dialogs.css), which
// asks where to save and lets the engine write the file, and the keyboard shortcuts.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';

/// A dialog's card: its title, its body and its buttons on the right.
class DialogCard extends StatelessWidget {
  const DialogCard({
    super.key,
    required this.title,
    required this.children,
    required this.actions,
    this.width = 440,
  });

  final String title;
  final List<Widget> children, actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: palette.dark ? const Color(0xFF222222) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 40, offset: Offset(0, 10))],
      ),
      child: DefaultTextStyle(
        style: editorText(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: editorText(context, size: TextSizes.dialog, weight: FontWeight.w700)),
            const SizedBox(height: 14),
            ...children,
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                actions[i],
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

// ── Export ────────────────────────────────────────────────────────────────────────────────────

void showExportDialog(BuildContext context, EditorModel editor) =>
    showModal(context, (close) => _ExportDialog(editor: editor, onClose: close));

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  String _type = 'image/jpeg';
  int? _size;
  double _quality = .95;
  String _metadata = 'preserve';
  String? _result;
  bool _busy = false;

  static const _types = [
    PickerOption('image/jpeg', 'JPEG'),
    PickerOption('image/heic', 'HEIC'),
    PickerOption('image/png', 'PNG'),
    PickerOption('image/tiff', 'TIFF (16-bit)'),
  ];
  static const _extensions = {
    'image/jpeg': 'jpg',
    'image/heic': 'heic',
    'image/png': 'png',
    'image/tiff': 'tiff',
  };

  Future<void> _export() async {
    final doc = widget.editor.active!;
    final ext = _extensions[_type]!;
    final base = doc.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final suggested = '$base-fotufilm.$ext';
    // A browser saves to its downloads; the desktop asks where.
    final path = kIsWeb
        ? suggested
        : (await getSaveLocation(
            suggestedName: suggested,
            acceptedTypeGroups: [XTypeGroup(label: ext.toUpperCase(), extensions: [ext])],
          ))
            ?.path;
    if (path == null) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final saved = await widget.editor.export(
        path: path,
        type: _type,
        quality: _quality,
        maxEdge: _size,
        metadata: _metadata,
      );
      _result = 'Saved ${saved.split('/').last}.';
    } catch (e) {
      _result = 'Export failed. $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _row(String label, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(label)),
          SizedBox(width: 200, child: control),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final doc = widget.editor.active!;
    final long = doc.width > doc.height ? doc.width : doc.height;
    final lossy = _type == 'image/jpeg' || _type == 'image/heic';
    return DialogCard(
      title: 'Export image',
      actions: [
        PillButton(_result != null ? 'Done' : 'Cancel', onPressed: _busy ? null : widget.onClose),
        PillButton('Export', variant: ButtonVariant.accent, onPressed: _busy ? null : _export),
      ],
      children: [
        _row('Format', PickerField<String>(
            value: _type, options: _types, onChanged: (v) => setState(() => _type = v))),
        _row(
          'Size',
          PickerField<int?>(
            value: _size,
            options: [
              PickerOption(null, 'Full size · $long px'),
              for (final edge in const [6000, 4096, 3000, 2048, 1080])
                if (edge < long) PickerOption(edge, '$edge px long edge'),
            ],
            onChanged: (v) => setState(() => _size = v),
          ),
        ),
        if (lossy)
          _row(
            'Quality',
            PickerField<double>(
              value: _quality,
              options: const [
                PickerOption(1.0, 'Maximum'),
                PickerOption(.95, 'High'),
                PickerOption(.85, 'Medium'),
                PickerOption(.7, 'Low'),
              ],
              onChanged: (v) => setState(() => _quality = v),
            ),
          ),
        _row(
          'Metadata',
          PickerField<String>(
            value: _metadata,
            options: const [
              PickerOption('preserve', 'Keep'),
              PickerOption('preserveWithoutLocation', 'Keep, without location'),
              PickerOption('strip', 'Remove'),
            ],
            onChanged: (v) => setState(() => _metadata = v),
          ),
        ),
        const SizedBox(height: 6),
        Note(_result ??
            (_busy
                ? 'Developing at full quality…'
                : 'The engine develops the photograph again at the chosen size, with exact math.')),
      ],
    );
  }
}

// ── Keyboard shortcuts ────────────────────────────────────────────────────────────────────────

/// The shortcuts the editor answers, as (what, keys).
void showShortcutsDialog(BuildContext context, List<(String, String)> rows) => showModal(
      context,
      (close) => DialogCard(
        title: 'Keyboard shortcuts',
        width: 400,
        actions: [PillButton('Done', variant: ButtonVariant.accent, onPressed: close)],
        children: [
          for (final (label, keys) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Builder(
                builder: (context) => Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label),
                    Text(keys, style: editorText(context, color: Palette.of(context).muted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
