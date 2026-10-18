// The transport's video settings: how the movie's codes are read, the trim, the export cadence the
// native exporter retimes to, and whether the sound goes with an export. They are the edit's
// (`edit.video`), so they undo and are kept with it.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'video_controls.dart' show videoLabel;

class VideoSettingsButton extends StatelessWidget {
  const VideoSettingsButton({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) => Builder(
        builder: (anchor) => QuietButton(
          key: const ValueKey('video-settings'),
          icon: 'adjustments',
          tooltip: videoLabel(editor, 'settings'),
          size: Metrics.videoButton,
          iconSize: Metrics.videoIcon,
          opensMenu: true,
          onPressed: editor.video.disabled ? null : () => showVideoSettings(anchor, editor),
        ),
      );
}

/// Opens the settings over `anchor`.
AnchoredOverlay showVideoSettings(BuildContext anchor, EditorModel editor) => showAnchored(
      anchor,
      (context, close) => PopoverSurface(
        child: ListenableBuilder(
          listenable: Listenable.merge([editor, editor.video]),
          builder: (context, _) => VideoSettingsPanel(editor: editor),
        ),
      ),
      alignEnd: true,
      above: true,
      width: Metrics.videoSettingsWidth,
    );

class VideoSettingsPanel extends StatelessWidget {
  const VideoSettingsPanel({super.key, required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final video = editor.video;
    final clip = video.clip;
    if (clip == null) return const SizedBox.shrink();
    String label(String key) => videoLabel(editor, key);
    final settings = video.settings;
    final (:start, :end) = video.range;
    final position = video.position;
    final enabled = !video.disabled;
    void setStart(double value) {
      if (value.isFinite && value >= clip.start && value < end) {
        video.changeSettings({'trimStart': value});
      }
    }

    void setEnd(double value) {
      if (value.isFinite && value > start && value <= clip.duration) {
        video.changeSettings({'trimEnd': value});
      }
    }

    // Retiming is the native exporter's; an engine without it keeps the source's rate.
    final cadence = (editor.engine?.capabilities['videoFrameRates'] as List?)?.isNotEmpty == true;
    final frameRate = (settings['frameRate'] as num?)?.toInt();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 14,
        children: [
          Text(label('settings'),
              style: editorText(context, size: TextSizes.heading, weight: FontWeight.w600)),
          PickerField<String>(
            label: label('encoding'),
            value: settings['encoding'] as String? ?? 'standard',
            enabled: enabled,
            options: [for (final (id, name) in videoEncodings) PickerOption(id, name)],
            onChanged: (encoding) => video.changeSettings({'encoding': encoding}),
          ),
          Column(spacing: 6, children: [
            Row(spacing: 8, children: [
              Expanded(
                child: _SecondsField(
                    label: label('trimStart'), value: start, enabled: enabled, onSubmitted: setStart),
              ),
              Expanded(
                child: _SecondsField(
                    label: label('trimEnd'), value: end, enabled: enabled, onSubmitted: setEnd),
              ),
            ]),
            Row(spacing: 8, children: [
              Expanded(
                child: QuietButton(
                    label: label('setIn'),
                    onPressed: enabled && position < end ? () => setStart(position) : null),
              ),
              Expanded(
                child: QuietButton(
                    label: label('setOut'),
                    onPressed: enabled && position > start ? () => setEnd(position) : null),
              ),
            ]),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: QuietButton(
              label: label('resetTrim'),
              onPressed: enabled && (start != clip.start || end != clip.duration)
                  ? () => video.changeSettings({'trimStart': clip.start, 'trimEnd': null})
                  : null,
            ),
          ),
          if (cadence) ...[
            PickerField<int?>(
              label: label('cadence'),
              value: frameRate,
              enabled: enabled,
              options: [for (final (rate, key) in videoCadences) PickerOption(rate, label(key))],
              onChanged: (rate) => video.changeSettings({'frameRate': rate}),
            ),
            Transform.translate(
              offset: const Offset(0, -8),
              child: Text(label('cadenceNote'),
                  style: editorText(context, color: Palette.of(context).muted)),
            ),
          ],
          SwitchRow(
            label: label('audio'),
            value: settings['audio'] != false,
            enabled: enabled,
            onChanged: (audio) => video.changeSettings({'audio': audio}),
          ),
        ],
      ),
    );
  }
}

/// A number of seconds to three places, labelled above, committed on Enter or leaving it.
class _SecondsField extends StatefulWidget {
  const _SecondsField(
      {required this.label, required this.value, required this.enabled, required this.onSubmitted});
  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onSubmitted;

  @override
  State<_SecondsField> createState() => _SecondsFieldState();
}

class _SecondsFieldState extends State<_SecondsField> {
  late final _controller = TextEditingController(text: _format(widget.value));
  final _focus = FocusNode();

  static String _format(double value) => formatNumber(value, decimals: 3);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_SecondsField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) _controller.text = _format(widget.value);
  }

  void _commit() {
    final parsed = double.tryParse(_controller.text.replaceAll(',', '').trim());
    if (parsed != null && parsed.isFinite && parsed != widget.value) widget.onSubmitted(parsed);
    // A value the trim refuses goes back to the one it has.
    if (mounted) _controller.text = _format(widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: widget.enabled ? 1 : .45,
        child: IgnorePointer(
          ignoring: !widget.enabled,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FieldLabel(widget.label),
            const SizedBox(height: 3),
            Container(
              height: Metrics.control,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                  color: Palette.of(context).gray100,
                  borderRadius: BorderRadius.circular(Metrics.radius)),
              child: EditableField(
                controller: _controller,
                focusNode: _focus,
                style: editorText(context),
                onSubmitted: (_) => _commit(),
              ),
            ),
          ]),
        ),
      );
}
