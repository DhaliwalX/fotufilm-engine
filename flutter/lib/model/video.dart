// Movies: what the engine said of an open one (its clip), the playhead and the transport, as the
// React editor's player keeps them (web/src/VideoControls.jsx, video-player/playback.js,
// useVideoPlayback.js, playback-quality.js) on the desktop backend (backend/desktop/session.js).
//
// The engine decodes and develops every frame; the editor only says which (`videoTime`). While a
// movie plays, each new frame develops at the Playback Quality's long edge as a `playback`
// preview, without its undeveloped original unless the comparison shows; one frame is in flight
// at a time and the newest time waits behind it, never cancelling it; the film rows and other
// background pictures wait. A paused frame develops at full detail.
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../app/soundtrack.dart';
import 'editor.dart';

/// The movie files the editor opens (media-types.js `VIDEO_ACCEPT`).
const videoExtensions = ['mp4', 'mov', 'm4v', 'webm', 'mkv'];

bool isVideoName(String name) => videoExtensions.contains(name.split('.').last.toLowerCase());

/// An open movie as the engine describes it (`image.video`): where its first frame starts, how
/// long it runs, its frame rate and whether it has sound.
class VideoClip {
  const VideoClip(
      {required this.start, required this.duration, required this.frameRate, this.audio = false});

  static VideoClip? of(Json? descriptor) {
    final video = descriptor?['video'];
    if (video is! Map) return null;
    double read(String key) => (video[key] as num?)?.toDouble() ?? 0;
    return VideoClip(
        start: read('start'),
        duration: read('duration'),
        frameRate: read('frameRate'),
        audio: video['audio'] == true);
  }

  final double start, duration, frameRate;
  final bool audio;

  /// The frame showing at `seconds`, counted from the first, as the engine counts them
  /// (HostVideo.swift `frameNumber`).
  int frameNumber(double seconds) =>
      math.max(0, ((seconds - start) * math.max(1, frameRate) + 1e-3).floor());
}

extension MovieDocument on PhotoDocument {
  /// The movie this document is, or null for a photograph.
  VideoClip? get clip => VideoClip.of(descriptor);
  bool get isMovie => descriptor['video'] is Map;
}

// ── The edit's video settings (editor-state.js `defaultEdit.video`) ──────────────────────────

const defaultVideoSettings = <String, dynamic>{
  'encoding': 'standard',
  'trimStart': 0,
  'trimEnd': null,
  'audio': true,
  'frameRate': null,
};

/// The edit's video settings, with the defaults for what it does not say.
Json videoSettings(Json edit) =>
    {...defaultVideoSettings, ...?(edit['video'] as Map?)?.cast<String, dynamic>()};

/// The trim within the clip: from trim in, or the first frame, to trim out, or the end
/// (VideoControls.jsx, video-settings.js `videoRange`).
({double start, double end}) videoRange(VideoClip clip, Json settings) => (
      start: math.max(clip.start, (settings['trimStart'] as num?)?.toDouble() ?? 0),
      end: math.min((settings['trimEnd'] as num?)?.toDouble() ?? clip.duration, clip.duration),
    );

/// How the movie's codes are read: its colour tags, or a camera's log (video-color.js
/// `VIDEO_ENCODINGS`, generated/video-color.json).
const videoEncodings = [
  ('standard', 'Standard · use color tags'),
  ('appleLog', 'Apple Log · Rec.2020'),
  ('appleLog2', 'Apple Log 2 · Apple Wide Gamut'),
  ('flog', 'F-Log · F-Gamut'),
  ('flog2', 'F-Log2 · F-Gamut'),
  ('flog2C', 'F-Log2 C · F-Gamut C'),
  ('hlg', 'HLG · Rec.2020'),
  ('slog2', 'S-Log2 · S-Gamut'),
  ('slog3', 'S-Log3 · S-Gamut3'),
  ('slog3Cine', 'S-Log3 · S-Gamut3.Cine'),
];

/// The Mac app's Cadence choices, by their VIDEO_LABELS keys; Native keeps the source's rate
/// (VideoSettings.jsx `CADENCES`).
const videoCadences = [
  (null, 'cadenceNative'),
  (16, 'cadence16'),
  (18, 'cadence18'),
  (24, 'cadence24'),
];

// ── Playback Quality and the clip summary (playback-quality.js) ─────────────────────────────

const playbackQualities = [
  ('draft', 'Draft', 640),
  ('standard', 'Standard', 1280),
  ('fine', 'Fine', 1920),
  ('full', 'Full · 4K', 3840),
];

const playbackQualityHelp =
    'Playback develops at this quality; the paused frame always develops at full resolution.';

(String, String, int) _quality(String? id) =>
    playbackQualities.firstWhere((q) => q.$1 == id, orElse: () => playbackQualities[2]);

/// The long edge a playing movie develops at.
int playbackEdge(String? id) => _quality(id).$3;
String playbackQualityLabel(String? id) => _quality(id).$2;

/// "24 fps", "29.97 fps", or "Variable fps" for a clip that names no rate.
String frameRateLabel(double rate) {
  if (!(rate > 0)) return 'Variable fps';
  return rate.roundToDouble() == rate ? '${rate.round()} fps' : '${rate.toStringAsFixed(2)} fps';
}

/// The line under the transport: the clip's frame size, rate, and whether it has sound.
String clipSummary(int width, int height, VideoClip clip) => [
      if (width > 0 && height > 0) '$width × $height',
      frameRateLabel(clip.frameRate),
      if (clip.audio) 'audio',
    ].join('   ');

/// 01:02.34, or 1:01:02.34 past an hour (time.js `videoTimeLabel`).
String videoTimeLabel(double time) {
  final hundredths = (math.max(0, time.isFinite ? time : 0) * 100).round();
  final seconds = hundredths ~/ 100, hours = seconds ~/ 3600, minutes = (seconds ~/ 60) % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  final tail = '${two(seconds % 60)}.${two(hundredths % 100)}';
  return hours > 0 ? '$hours:${two(minutes)}:$tail' : '${two(minutes)}:$tail';
}

/// A playhead inside the trim, a hair before its end (time.js `clampPlayhead`).
double clampPlayhead(double value, double start, double end) => math.max(
    start, math.min(end - math.min(0.001, (end - start) / 2), value.isFinite ? value : start));

// ── The transport ─────────────────────────────────────────────────────────────────────────

/// A frame put on screen while playing: when (ms after Play), which time of the movie, and how
/// long the engine took to develop it.
typedef PlayedFrame = ({int at, double time, double develop});

class VideoPlayer extends ChangeNotifier {
  VideoPlayer(this.editor) {
    editor.renderOptionSources.add(_options);
    editor.addListener(_follow);
  }

  final EditorModel editor;
  final _sound = Soundtrack();

  /// The playhead, in seconds of the shown movie.
  double _time = 0;
  double get position => _time;

  bool playing = false;

  /// The seek bar is being dragged: its frames develop as playing ones do.
  bool scrubbing = false;
  bool loop = false, muted = false;
  double rate = 1;

  /// Why the movie cannot play, shown under the transport.
  String? error;

  /// The playing clock: where it started in the movie and the wall time since.
  double _anchor = 0;
  final _clock = Stopwatch();
  Ticker? _ticker;

  /// The frames shown since the last Play, for timing checks.
  final List<PlayedFrame> played = [];
  final _sinceStart = Stopwatch();
  int _developed = 0;

  PhotoDocument? _shown;

  PhotoDocument? get _movie {
    final doc = editor.active;
    return doc != null && doc.isMovie ? doc : null;
  }

  VideoClip? get clip => _movie?.clip;
  Json get settings => videoSettings(editor.edit);

  /// The trim of the shown movie.
  ({double start, double end}) get range {
    final clip = this.clip;
    return clip == null ? (start: 0, end: 0) : videoRange(clip, settings);
  }

  /// While an export runs or the crop tool is open the transport rests (EditorViewer.jsx).
  bool get disabled => editor.exporting || editor.crop.showing;
  bool get canPlay => _movie != null && !disabled;

  // ── Playback Quality (an app setting, chosen from the transport) ───────────────────────────

  String get quality => editor.settings.get<String>('videoPlaybackQuality') ?? 'fine';
  set quality(String id) {
    editor.settings.set('videoPlaybackQuality', id);
    notifyListeners();
  }

  // ── What the shown movie's develops ask for (session.js `renderRequest`) ────────────────────

  Json _options(PhotoDocument doc) {
    if (!doc.isMovie) return const {};
    final moving = doc == editor.active && (playing || scrubbing);
    return {
      'videoTime': doc == editor.active ? _time : doc.clip!.start,
      if (moving) ...{
        'previewQuality': 'playback',
        'draft': false,
        // A movie playing without the comparison leaves its undeveloped frame undrawn.
        'original': editor.comparing,
        if (playing) 'maxEdge': playbackEdge(quality),
      },
    };
  }

  /// Follows the editor: another photograph shown starts its movie at the first frame (as
  /// useDocumentActions.js resets `videoTime`), and the transport rests while it is disabled.
  /// While playing, it notes each frame put on screen.
  void _follow() {
    final doc = editor.active;
    if (doc != _shown) {
      _shown = doc;
      if (playing) _stop();
      scrubbing = false;
      error = null;
      // Each movie's player starts afresh, as React keys VideoControls by the document.
      loop = muted = false;
      rate = 1;
      final clip = doc?.clip;
      _time = clip?.start ?? 0;
      _sound.load(clip != null && clip.audio ? doc!.path : null);
      notifyListeners();
    }
    if (playing) {
      if (disabled) {
        // Paused after this notification, which the pause adds to.
        Future.microtask(pause);
      }
      final renderer = editor.renderer;
      if (renderer != null && renderer.developed != _developed) {
        _developed = renderer.developed;
        played.add((
          at: _sinceStart.elapsedMilliseconds,
          time: (doc?.shownRequest?['videoTime'] as num?)?.toDouble() ?? -1,
          develop: (renderer.lastPreview?['renderMilliseconds'] as num?)?.toDouble() ?? 0,
        ));
      }
    }
  }

  void toggle() => playing ? pause() : play();

  void play() {
    final doc = _movie;
    if (doc == null || disabled || playing) return;
    final (:start, :end) = range;
    if (_time < start || _time >= end - 0.002) _time = start;
    playing = true;
    error = null;
    // The magnified detail is of the paused frame; the playing preview carries the picture.
    doc.detail = null;
    played.clear();
    _developed = editor.renderer?.developed ?? 0;
    _sinceStart
      ..reset()
      ..start();
    _restartClock();
    (_ticker ??= Ticker(_tick))
      ..stop()
      ..start();
    editor.renderer?.playing = true;
    _playSound();
    _changed();
    editor.renderer?.schedule(interactive: true);
  }

  /// Pauses, and the frame on show develops again at full detail.
  void pause() {
    if (!playing) return;
    _stop();
    _changed();
    editor.renderer?.schedule();
  }

  void _stop() {
    playing = false;
    _ticker?.stop();
    _clock.stop();
    _sinceStart.stop();
    _sound.pause();
    editor.renderer?.playing = scrubbing;
  }

  void _restartClock() {
    _anchor = _time;
    _clock
      ..reset()
      ..start();
  }

  void _playSound() {
    if (clip?.audio == true) _sound.play(_time, rate: rate, muted: muted);
  }

  void _tick(Duration _) {
    final (:start, :end) = range;
    final time = _anchor + _clock.elapsedMicroseconds / 1e6 * rate;
    if (time >= end) {
      if (loop) {
        _moveTo(start, interactive: true);
        _restartClock();
        _playSound();
      } else {
        // The end of the trim: it stops on its last frame.
        _time = clampPlayhead(end, start, end);
        pause();
      }
      return;
    }
    _moveTo(time, interactive: true);
  }

  /// Moves the playhead; a new frame asks for its picture.
  void _moveTo(double time, {required bool interactive}) {
    final clip = this.clip;
    if (clip == null) return;
    final before = clip.frameNumber(_time);
    _time = time;
    notifyListeners();
    if (clip.frameNumber(time) != before) editor.renderer?.schedule(interactive: interactive);
  }

  /// Shows the frame at `value`, pausing first (playback.js `seek`).
  void seek(double value) {
    if (disabled || clip == null) return;
    if (playing) {
      _stop();
      _changed();
    }
    final (:start, :end) = range;
    final before = _time;
    _moveTo(clampPlayhead(value, start, end), interactive: scrubbing);
    // A seek within the frame on show still settles it.
    if (!scrubbing && _time != before) editor.renderer?.schedule();
  }

  void skip(double seconds) => seek(_time + seconds);

  /// The seek bar taken and let go: while it moves its frames develop as playing ones do.
  void startScrub() {
    if (disabled || clip == null) return;
    scrubbing = true;
    if (playing) {
      _stop();
      _changed();
    }
    editor.renderer?.playing = true;
  }

  void endScrub() {
    if (!scrubbing) return;
    scrubbing = false;
    editor.renderer?.playing = playing;
    notifyListeners();
    editor.renderer?.schedule();
  }

  void setLoop(bool value) {
    loop = value;
    notifyListeners();
  }

  void setMuted(bool value) {
    muted = value;
    _sound.setMuted(value);
    notifyListeners();
  }

  void setRate(double value) {
    rate = value;
    if (playing) {
      _restartClock();
      _playSound();
    }
    notifyListeners();
  }

  /// Changes the edit's video settings; a playhead the new trim leaves out goes to its start
  /// (playback.js `configure`).
  void changeSettings(Json changes) {
    editor.change({'video': {...settings, ...changes}});
    final (:start, :end) = range;
    if (_time < start || _time >= end) seek(start);
  }

  void _changed() {
    notifyListeners();
    // View › Play reads Pause while a movie plays.
    editor.notify();
  }

  // ── Opening movies (ImportMenu.jsx Video) ──────────────────────────────────────────────────

  /// Chooses movies to open; one brings its folder into the strip, as Open… does.
  Future<void> chooseMovies() async {
    if (!editor.ready || editor.exporting) return;
    final files = await openFiles(acceptedTypeGroups: const [
      XTypeGroup(label: 'Videos', extensions: videoExtensions),
    ]);
    await editor.strip.open([
      for (final f in files) PhotoFile(f.name, path: kIsWeb ? null : f.path, read: f.readAsBytes),
    ]);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }
}
