// Exports running in the background, in the title bar: a ring beside Export that fills as the
// running export goes, and a click on it opens what it is doing, the exports waiting after it and
// Cancel for each.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/export.dart' show ExportJob;
import '../kit/kit.dart';
import '../theme/theme.dart';

class ExportProgressButton extends StatefulWidget {
  const ExportProgressButton({super.key, required this.editor, this.size = Metrics.control});
  final EditorModel editor;
  final double size;

  @override
  State<ExportProgressButton> createState() => _ExportProgressButtonState();
}

class _ExportProgressButtonState extends State<ExportProgressButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final jobs = widget.editor.exporter.jobs;
    final job = jobs.firstOrNull;
    if (job == null) return const SizedBox.shrink();
    final palette = Palette.of(context);
    final waiting = jobs.length - 1;
    return HoverTip(
      message: '${job.detail ?? 'Exporting ${job.title}'}${waiting > 0 ? ' · $waiting more waiting' : ''}',
      child: PressTrigger(
        onPress: () => showAnchored(context, (_, close) => _ExportPanel(widget.editor, close),
            alignEnd: true, width: 300),
        child: tinted(
          child: Container(
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? palette.hover : null,
              borderRadius: BorderRadius.circular(Metrics.radius),
            ),
            child: ProgressRing(value: job.progress, size: 16),
          ),
        ),
      ),
    );
  }
}

/// A small ring filled to `value`, or a turning arc while the amount is unknown (null).
class ProgressRing extends StatefulWidget {
  const ProgressRing({super.key, this.value, this.size = 16});
  final double? value;
  final double size;

  @override
  State<ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<ProgressRing> with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ProgressRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.value == null && !_turn.isAnimating) _turn.repeat();
    if (widget.value != null && _turn.isAnimating) _turn.stop();
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _Ring(
          value: widget.value,
          turn: _turn.value,
          track: palette.gray300,
          fill: palette.accent,
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring({required this.value, required this.turn, required this.track, required this.fill});
  final double? value;
  final double turn;
  final Color track, fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
    final value = this.value;
    final (start, sweep) = value == null
        ? (2 * math.pi * turn - math.pi / 2, math.pi / 2)
        : (-math.pi / 2, 2 * math.pi * value.clamp(0.02, 1.0));
    canvas.drawArc(rect, start, sweep, false, paint..color = fill);
  }

  @override
  bool shouldRepaint(_Ring old) =>
      old.value != value || old.turn != turn || old.track != track || old.fill != fill;
}

/// What the ring opens: the running export and the ones waiting, each with Cancel. It closes
/// when the last is done.
class _ExportPanel extends StatelessWidget {
  const _ExportPanel(this.editor, this.close);
  final EditorModel editor;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor,
        builder: (context, _) {
          final jobs = editor.exporter.jobs;
          if (jobs.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) => close());
            return const SizedBox.shrink();
          }
          return PopoverSurface(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, job) in jobs.indexed) ...[
                    if (index > 0) const SizedBox(height: 10),
                    _JobRow(editor, job),
                  ],
                ],
              ),
            ),
          );
        },
      );
}

class _JobRow extends StatelessWidget {
  const _JobRow(this.editor, this.job);
  final EditorModel editor;
  final ExportJob job;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(job.running ? job.detail ?? 'Exporting ${job.title}' : job.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: editorText(context, color: palette.text)),
          const SizedBox(height: 6),
          if (job.running)
            ProgressBar(value: job.progress)
          else
            Text('Waiting', style: editorText(context, size: TextSizes.caption, color: palette.muted)),
        ]),
      ),
      const SizedBox(width: 12),
      QuietButton(
        icon: 'close',
        tooltip: job.running ? 'Cancel export' : 'Remove from queue',
        iconSize: 14,
        onPressed: () => editor.exporter.cancelJob(job),
      ),
    ]);
  }
}
