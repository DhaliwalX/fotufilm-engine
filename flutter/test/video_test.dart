import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/export.dart';
import 'package:fotufilm_flutter/model/video.dart';

void main() {
  group('video player (video-player/time.js, playback-quality.js)', () {
    test('time labels', () {
      expect(videoTimeLabel(0), '00:00.00');
      expect(videoTimeLabel(65.239), '01:05.24');
      expect(videoTimeLabel(3723.5), '1:02:03.50');
      expect(videoTimeLabel(double.nan), '00:00.00');
    });

    test('the playhead stays inside the trim, a hair before its end', () {
      expect(clampPlayhead(5, 1, 4), closeTo(3.999, 1e-9));
      expect(clampPlayhead(-1, 1, 4), 1);
      expect(clampPlayhead(2, 1, 4), 2);
      expect(clampPlayhead(double.infinity, 1, 4), 1);
    });

    test('playback quality edges and labels', () {
      expect(playbackEdge('draft'), 640);
      expect(playbackEdge('full'), 3840);
      expect(playbackEdge(null), 1920);
      expect(playbackQualityLabel('unknown'), 'Fine');
    });

    test('the clip summary', () {
      const clip = VideoClip(start: 0, duration: 4, frameRate: 29.97, audio: true);
      expect(clipSummary(1920, 1080, clip), '1920 × 1080   29.97 fps   audio');
      expect(frameRateLabel(24), '24 fps');
      expect(frameRateLabel(0), 'Variable fps');
    });
  });

  group('clips and their settings', () {
    test('a descriptor names a clip; a photograph has none', () {
      final clip = VideoClip.of({
        'video': {'start': 0.5, 'duration': 4, 'frameRate': 24, 'audio': true},
      })!;
      expect((clip.start, clip.duration, clip.frameRate, clip.audio), (0.5, 4.0, 24.0, true));
      expect(VideoClip.of({'naturalWidth': 10}), isNull);
    });

    test('frames count from the first, as the engine counts them', () {
      const clip = VideoClip(start: 0.5, duration: 4, frameRate: 24);
      expect(clip.frameNumber(0.5), 0);
      expect(clip.frameNumber(0.5 + 1 / 24), 1);
      expect(clip.frameNumber(0.2), 0);
    });

    test('the trim falls inside the clip and defaults to all of it', () {
      const clip = VideoClip(start: 0.5, duration: 4, frameRate: 24);
      expect(videoRange(clip, videoSettings({})), (start: 0.5, end: 4.0));
      final settings = videoSettings({
        'video': {'trimStart': 1, 'trimEnd': 9},
      });
      expect(videoRange(clip, settings), (start: 1.0, end: 4.0));
      expect(settings['encoding'], 'standard');
      expect(settings['audio'], true);
    });

    test('movie names', () {
      expect(isVideoName('a.MOV'), isTrue);
      expect(isVideoName('a.mkv'), isTrue);
      expect(isVideoName('a.jpg'), isFalse);
    });
  });

  group('movie export sizes (export-sizes.js VIDEO_EDGES)', () {
    test('a 4K movie offers its source, then the video sizes below it', () {
      final sizes = exportSizeOptions((width: 3840, height: 2160), video: true);
      expect(sizes.map((s) => s.id), ['full', '2560', '1920', '1280']);
      expect(sizes.first.label, 'Source');
      expect(sizes[2].label, '1080p');
      expect(sizes[2].detail, '1920 × 1080');
    });

    test('codecs take even sizes', () {
      expect(evenSize((width: 1919, height: 1079)), (width: 1920, height: 1080));
      expect(evenSize((width: 1, height: 1)), (width: 2, height: 2));
    });
  });
}
