// What an export just saved (web/src/editor/SavedExportNotice.jsx, styles/video.css
// `.saved-export`): a dark card at the window's foot with Open (the system's viewer for it), Show
// in Finder and Dismiss. Export All saved many files, so only Show in Finder is offered for it.
// Above it while exports run in the background: the running one's progress, how many wait, and
// Cancel.
import 'package:flutter/widgets.dart';

import '../../app/host_window.dart';
import '../../model/editor.dart';
import '../../model/export.dart' show ExportJob, SavedExport;
import '../kit/kit.dart';
import '../theme/theme.dart';

class SavedExportNotice extends StatelessWidget {
  const SavedExportNotice({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final saved = editor.exporter.saved;
    final jobs = editor.exporter.jobs;
    if (saved == null && jobs.isEmpty) return const SizedBox.shrink();
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (jobs.isNotEmpty) _progress(context, jobs),
        if (jobs.isNotEmpty && saved != null) const SizedBox(height: 8),
        if (saved != null) _saved(context, saved),
      ]),
    );
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

  Widget _progress(BuildContext context, List<ExportJob> jobs) {
    final job = jobs.first;
    final waiting = jobs.length - 1;
    const white = Color(0xFFFFFFFF);
    return _card(SizedBox(
      width: 360,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(job.detail ?? 'Exporting ${job.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: editorText(context, color: white)),
            const SizedBox(height: 8),
            ProgressBar(value: job.progress),
            if (waiting > 0) ...[
              const SizedBox(height: 6),
              Text('$waiting more waiting',
                  style: editorText(context, size: TextSizes.caption, color: const Color(0xFFBBBBBB))),
            ],
          ]),
        ),
        const SizedBox(width: 16),
        _NoticeButton('Cancel', () => editor.exporter.cancelJob(job)),
      ]),
    ));
  }

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
