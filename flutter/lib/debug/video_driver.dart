// The driver's commands for movies (driver.dart): the transport, the settings and the export.
//
//   {"video": true}                  logs the shown movie: its clip, playhead, trim and settings
//   {"play": 3000}                   plays for 3000 ms, pauses and logs the frames that reached
//                                    the screen: how many, the fps, the gaps and develop times
//   {"playToggle": true}             Play or Pause, as View › Play does
//   {"seek": 1.5}                    moves the playhead (paused)
//   {"scrub": [0.5, 3.0, 30]}        drags the seek bar from 0.5 s to 3 s in 30 steps a frame
//                                    apart and logs how many frames reached the screen
//   {"videoSettings": {"trimStart": 1}}  changes the edit's video settings
//   {"playbackQuality": "draft"}     the transport's Playback Quality
//   {"loop": true}                   loops the selection
//   {"videoFormat": "hevc10"}        the export dialog's movie format
//   {"exportVideo": "/out.mp4"}      exports the movie with the dialog's settings and logs the
//                                    statuses it showed; add "cancelAfter": ms to cancel it
//   {"videoPopover": true}           opens the transport's video settings
//   {"exportDialog": true}           opens the Export dialog (false closes it)
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../model/editor.dart';
import '../ui/kit/popover.dart';
import '../ui/workspace/export_dialog.dart';
import '../ui/workspace/video_settings.dart';

AnchoredOverlay? _overlay, _dialog;

Future<void> runVideoCommand(
    Map<String, dynamic> c, EditorModel editor, GlobalKey boundary, void Function(String) log) async {
  final video = editor.video;
  if (c['playbackQuality'] case final String id) video.quality = id;
  if (c['videoSettings'] case final Map changes) video.changeSettings(changes.cast());
  if (c['seek'] case final num time) video.seek(time.toDouble());
  if (c['playToggle'] == true) video.toggle();
  if (c['loop'] case final bool on) video.setLoop(on);
  if (c['play'] case final int ms) {
    video.play();
    await Future<void>.delayed(Duration(milliseconds: ms));
    final frames = [...video.played];
    video.pause();
    final gaps = [for (var i = 1; i < frames.length; i++) frames[i].at - frames[i - 1].at]..sort();
    final develops = [for (final f in frames) f.develop.round()]..sort();
    int median(List<int> v) => v.isEmpty ? 0 : v[v.length ~/ 2];
    final span = frames.length < 2 ? 0 : frames.last.at - frames.first.at;
    log('played ${ms}ms quality=${video.quality} frames=${frames.length} '
        'fps=${span > 0 ? ((frames.length - 1) * 1000 / span).toStringAsFixed(1) : 0} '
        'gap median=${median(gaps)}ms max=${gaps.isEmpty ? 0 : gaps.last}ms '
        'develop median=${median(develops)}ms max=${develops.isEmpty ? 0 : develops.last}ms '
        'times=${frames.take(12).map((f) => f.time.toStringAsFixed(3)).join(',')}… '
        'position=${video.position.toStringAsFixed(3)}');
  }
  if (c['scrub'] case [final num from, final num to, final int steps]) {
    final renderer = editor.renderer!;
    final before = renderer.developed;
    video.startScrub();
    for (var i = 0; i <= steps; i++) {
      video.seek(from + (to - from) * i / steps);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final shown = renderer.developed - before;
    final settle = Stopwatch()..start();
    video.endScrub();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    while (renderer.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    log('scrubbed $steps steps frames=$shown settle=${settle.elapsedMilliseconds}ms '
        'position=${video.position.toStringAsFixed(3)}');
  }
  if (c['videoFormat'] case final String id) editor.exporter.videoFormat = id;
  if (c['exportVideo'] case final String path) {
    if (c['cancelAfter'] case final int ms) Timer(Duration(milliseconds: ms), editor.exporter.cancel);
    final clock = Stopwatch()..start();
    final shown = <String>[];
    final watch = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final status = editor.status;
      if (status != null && (shown.isEmpty || shown.last != status)) shown.add(status);
    });
    final saved = await editor.exporter.exportMovie(path: path);
    watch.cancel();
    log('exportVideo ${saved?.path} ${clock.elapsedMilliseconds}ms error=${editor.error} '
        'statuses=${shown.length > 6 ? [...shown.take(3), '…', ...shown.skip(shown.length - 3)] : shown}');
  }
  if (c['video'] == true) {
    final doc = editor.active;
    final clip = doc?.clip;
    final (:start, :end) = video.range;
    log(clip == null
        ? 'video none'
        : 'video ${doc!.name} ${doc.width}x${doc.height} start=${clip.start} '
            'duration=${clip.duration} fps=${clip.frameRate} audio=${clip.audio} '
            'position=${video.position.toStringAsFixed(3)} playing=${video.playing} '
            'range=$start-$end settings=${video.settings} '
            'shown=${doc.shownRequest?['videoTime']} stock=${doc.edit['stock']}');
  }
  if (c['videoPopover'] == true) {
    _overlay?.close();
    final anchor = _find(boundary, const ValueKey('video-settings'));
    if (anchor != null && anchor.mounted) _overlay = showVideoSettings(anchor, editor);
  }
  if (c['videoPopover'] == false) _overlay?.close();
  if (c['exportDialog'] == true) {
    final anchor = _find(boundary, const ValueKey('video-controls'));
    if (anchor != null && anchor.mounted) {
      _dialog = showModal(anchor, (close) => ExportDialog(editor: editor, onClose: close));
    }
  }
  if (c['exportDialog'] == false) _dialog?.close();
}

/// The element of the widget with `key`.
BuildContext? _find(GlobalKey boundary, Key key) {
  BuildContext? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget.key == key) {
      found = element;
      return;
    }
    element.visitChildElements(visit);
  }

  boundary.currentContext?.visitChildElements(visit);
  return found;
}
