// What an export just saved (web/src/editor/SavedExportNotice.jsx, styles/video.css
// `.saved-export`): a dark card at the window's foot with Open (the system's viewer for it), Show
// in Finder and Dismiss. Export All saved many files, so only Show in Finder is offered for it.
import 'package:flutter/widgets.dart';

import '../../app/host_window.dart';
import '../../model/editor.dart';
import '../../model/export.dart' show SavedExport;
import '../kit/kit.dart';
import '../theme/theme.dart';

class SavedExportNotice extends StatelessWidget {
  const SavedExportNotice({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final saved = editor.exporter.saved;
    if (saved == null) return const SizedBox.shrink();
    return Positioned(
        bottom: 24,
        left: 0,
        right: 0,
        child: Appear(key: ValueKey(saved), rise: 8, child: _saved(context, saved)));
  }

  static Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF222222),
          border: Border.all(color: const Color(0xFF666666)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );

  Widget _saved(BuildContext context, SavedExport saved) => Center(
        child: _card(Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Saved ${saved.filename}',
                style: editorText(context, color: const Color(0xFFFFFFFF))),
            const SizedBox(width: 16),
            if (saved.count == null) ...[
              _NoticeButton('Open', () => HostWindow.openFile(saved.path)),
              const SizedBox(width: 16),
            ],
            _NoticeButton('Show in Finder', () => HostWindow.reveal([saved.path])),
            const SizedBox(width: 16),
            _NoticeButton('Dismiss', editor.exporter.dismissSaved),
          ])),
      );
}

/// Spectrum's ActionButton at size S, on the notice's dark card in either appearance.
class _NoticeButton extends StatefulWidget {
  const _NoticeButton(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;

  @override
  State<_NoticeButton> createState() => _NoticeButtonState();
}

class _NoticeButtonState extends State<_NoticeButton> with PointerTint {
  @override
  Widget build(BuildContext context) => tinted(
        onTap: widget.onPressed,
        child: Container(
          height: Metrics.control,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovered ? const Color(0xFF444444) : const Color(0xFF333333),
            borderRadius: BorderRadius.circular(Metrics.radius),
          ),
          child: Text(widget.label,
              style: editorText(context, weight: FontWeight.w500, color: const Color(0xFFFFFFFF))),
        ),
      );
}
