// A movie's controls under the viewer (web/src/VideoControls.jsx, video-player/VideoTimeline.jsx,
// VideoTransport.jsx, PlayerButton.jsx, styles/video.css): the time and the seek bar with the
// trim under it, back and forward five seconds round Play, then loop, mute, speed, Playback
// Quality and the video settings, and the clip at a glance. The keys the player takes while the
// viewer has the keyboard are in `VideoKeys`.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'video_settings.dart';

/// The labels the React player uses (generated/controls.js `VIDEO_LABELS`).
String videoLabel(EditorModel editor, String key) =>
    ((editor.catalogue.module['VIDEO_LABELS'] as Map?)?[key] as String?) ?? key;

class VideoControls extends StatelessWidget {
  const VideoControls({super.key, required this.editor, required this.doc});
  final EditorModel editor;
  final PhotoDocument doc;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.video,
        builder: (context, _) {
          final clip = doc.clip;
          if (clip == null) return const SizedBox.shrink();
          final palette = Palette.of(context);
          final video = editor.video;
          return Container(
            key: const ValueKey('video-controls'),
            color: palette.panel,
            padding: editor.layout.compact ? Metrics.videoPaddingCompact : Metrics.videoPadding,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Timeline(editor: editor, clip: clip),
              _Transport(editor: editor),
              // The clip at a glance, as the Mac app prints it under its transport.
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(clipSummary(doc.width, doc.height, clip),
                    textAlign: TextAlign.center,
                    style: editorText(context, size: TextSizes.caption, color: palette.muted)),
              ),
              if (video.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(video.error!,
                      style: editorText(context, color: palette.muted)),
                ),
            ]),
          );
        },
      );
}

/// The time, the selection's length when trimmed, the seek bar and the trim under it.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.editor, required this.clip});
  final EditorModel editor;
  final VideoClip clip;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final video = editor.video;
    final (:start, :end) = video.range;
    final trimmed = start > clip.start || end < clip.duration;
    final span = clip.duration - clip.start;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(
                text: videoTimeLabel(video.position),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(
                text: ' / ${videoTimeLabel(clip.duration)}',
                style: TextStyle(color: palette.muted)),
          ]),
          key: const ValueKey('video-time'),
          style: editorText(context),
        ),
        const Spacer(),
        if (trimmed)
          Text('${videoLabel(editor, 'selection')} · ${videoTimeLabel(end - start)}',
              style: editorText(context, size: TextSizes.label, color: palette.muted)),
      ]),
      _SeekBar(
        value: video.position,
        min: clip.start,
        max: clip.duration,
        enabled: !video.disabled,
        onStart: video.startScrub,
        onChanged: video.seek,
        onEnd: video.endScrub,
      ),
      // Where the trim lies on the clip.
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 1, 6, 5),
        child: SizedBox(
          height: 2,
          child: LayoutBuilder(builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(children: [
              if (trimmed)
                Positioned.fill(
                    child: ColoredBox(color: palette.muted.withValues(alpha: .12))),
              if (trimmed && span > 0)
                Positioned(
                  left: width * (start - clip.start) / span,
                  width: width * (end - start) / span,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: palette.accent.withValues(alpha: .45)),
                ),
            ]);
          }),
        ),
      ),
    ]);
  }
}

/// Spectrum's emphasized Slider: the played part in the accent, the knob at the playhead.
class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
  });

  final double value, min, max;
  final bool enabled;
  final VoidCallback onStart, onEnd;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      const knob = Metrics.knob;
      double at(double dx) =>
          min + ((dx - knob / 2) / (width - knob)).clamp(0.0, 1.0) * (max - min);
      return Opacity(
        opacity: enabled ? 1 : .45,
        child: GestureDetector(
          key: const ValueKey('video-seek'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) {
                  onStart();
                  onChanged(at(d.localPosition.dx));
                }
              : null,
          onHorizontalDragUpdate: enabled ? (d) => onChanged(at(d.localPosition.dx)) : null,
          onHorizontalDragEnd: enabled ? (_) => onEnd() : null,
          onTapUp: enabled ? (d) => onChanged(at(d.localPosition.dx)) : null,
          child: SizedBox(
            height: Metrics.videoSeekHeight,
            child: CustomPaint(
              painter: _SeekPainter(
                  max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0) : 0, palette),
            ),
          ),
        ),
      );
    });
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter(this.t, this.palette);
  final double t;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    const knob = Metrics.knob;
    final y = size.height / 2;
    final x = knob / 2 + t * (size.width - knob);
    canvas.drawRRect(
        RRect.fromLTRBR(knob / 2, y - 2, size.width - knob / 2, y + 2, const Radius.circular(2)),
        Paint()..color = palette.gray300);
    canvas.drawRRect(RRect.fromLTRBR(knob / 2, y - 2, x, y + 2, const Radius.circular(2)),
        Paint()..color = palette.accent);
    canvas.drawCircle(
        Offset(x, y + 1),
        knob / 2 + .5,
        Paint()
          ..color = const Color(0x40000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    canvas.drawCircle(Offset(x, y), knob / 2,
        Paint()..color = palette.dark ? const Color(0xFFF2F2F2) : const Color(0xFFFFFFFF));
    canvas.drawCircle(
        Offset(x, y),
        knob / 2 - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = palette.accent);
  }

  @override
  bool shouldRepaint(_SeekPainter old) => old.t != t || old.palette != palette;
}

/// Back, Play and Forward; then loop, mute, speed, Playback Quality and the settings.
class _Transport extends StatelessWidget {
  const _Transport({required this.editor});
  final EditorModel editor;

  @override
  Widget build(BuildContext context) {
    final video = editor.video;
    final on = !video.disabled;
    String label(String key) => videoLabel(editor, key);
    Widget button(String icon, String tooltip, VoidCallback run, {bool? selected}) => QuietButton(
          icon: icon,
          tooltip: tooltip,
          selected: selected ?? false,
          size: Metrics.videoButton,
          iconSize: Metrics.videoIcon,
          onPressed: on ? run : null,
        );
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: [
          button('replay5', label('back'), () => video.skip(-5)),
          _PlayButton(
            playing: video.playing,
            tooltip: label(video.playing ? 'pause' : 'play'),
            onPressed: on ? video.toggle : null,
          ),
          button('forward5', label('forward'), () => video.skip(5)),
        ]),
        Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: [
          button('loop', label('loop'), () => video.setLoop(!video.loop), selected: video.loop),
          button(video.muted ? 'muted' : 'volume', label(video.muted ? 'unmute' : 'mute'),
              () => video.setMuted(!video.muted),
              selected: video.muted),
          _MenuButton(
            key: const ValueKey('video-speed'),
            text: '${_rate(video.rate)}×',
            tooltip: label('speed'),
            enabled: on,
            items: [
              for (final speed in const [0.25, 0.5, 1.0, 1.5, 2.0])
                MenuItem(
                  label: '${_rate(speed)}×',
                  checked: speed == video.rate,
                  onSelected: () => video.setRate(speed),
                ),
            ],
          ),
          _MenuButton(
            key: const ValueKey('video-quality'),
            text: playbackQualityLabel(video.quality),
            tooltip: playbackQualityHelp,
            enabled: on,
            items: [
              for (final (id, name, _) in playbackQualities)
                MenuItem(
                  label: name,
                  checked: id == video.quality,
                  onSelected: () => video.quality = id,
                ),
            ],
          ),
          VideoSettingsButton(editor: editor),
        ]),
      ],
    );
  }

  /// 0.25, 1 or 1.5, as JavaScript writes a number.
  static String _rate(double rate) =>
      rate == rate.roundToDouble() ? '${rate.round()}' : '$rate';
}

/// Play and Pause: the larger round button between the skips.
class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.playing, required this.tooltip, required this.onPressed});
  final bool playing;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> with PointerTint {
  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final enabled = widget.onPressed != null;
    return HoverTip(
      message: widget.tooltip,
      child: tinted(
        onTap: widget.onPressed,
        child: Container(
          key: const ValueKey('video-play'),
          width: Metrics.videoPlayButton,
          height: Metrics.videoPlayButton,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pressed
                ? Color.lerp(palette.gray100, palette.text, .12)
                : hovered && enabled
                    ? Color.lerp(palette.gray100, palette.text, .06)
                    : palette.gray100,
          ),
          alignment: Alignment.center,
          child: AppIcon(widget.playing ? 'pause' : 'play',
              size: Metrics.videoIcon + 2,
              color: enabled ? palette.text : palette.text.withValues(alpha: .3)),
        ),
      ),
    );
  }
}

/// A quiet text button that opens a menu over itself (the speed and the quality).
class _MenuButton extends StatelessWidget {
  const _MenuButton(
      {super.key,
      required this.text,
      required this.tooltip,
      required this.items,
      required this.enabled});
  final String text, tooltip;
  final List<MenuItem> items;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Builder(
        builder: (anchor) => QuietButton(
          label: text,
          tooltip: tooltip,
          size: Metrics.videoButton,
          onPressed:
              enabled ? () => showMenu(anchor, items, alignEnd: true, width: 140, above: true) : null,
        ),
      );
}

/// The player's keys while the viewer has the keyboard (usePlayerShortcuts.js): Space and K play
/// and pause, J and ← go back five seconds, L and → forward, M mutes. Elsewhere Space still shows
/// the original. A click in the viewer gives it the keyboard while a movie is shown.
class VideoKeys extends StatefulWidget {
  const VideoKeys({super.key, required this.editor, required this.child});
  final EditorModel editor;
  final Widget child;

  @override
  State<VideoKeys> createState() => _VideoKeysState();
}

class _VideoKeysState extends State<VideoKeys> {
  final _focus = FocusNode(debugLabel: 'viewer');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final video = widget.editor.video;
    if (widget.editor.active?.isMovie != true || video.disabled) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final mine = [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyM,
    ].contains(key);
    if (!mine) return KeyEventResult.ignored;
    // Repeats and releases are the player's too, so they do not reach Space-to-compare.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      video.toggle();
    } else if (key == LogicalKeyboardKey.keyJ || key == LogicalKeyboardKey.arrowLeft) {
      video.skip(-5);
    } else if (key == LogicalKeyboardKey.keyL || key == LogicalKeyboardKey.arrowRight) {
      video.skip(5);
    } else {
      video.setMuted(!video.muted);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        child: Listener(
          onPointerDown: (_) {
            if (widget.editor.active?.isMovie == true) _focus.requestFocus();
          },
          child: widget.child,
        ),
      );
}
