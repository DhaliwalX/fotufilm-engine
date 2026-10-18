// A playing movie's sound: the platform plays the movie file's own sound (MainFlutterWindow.swift
// `SoundtrackChannel`) beside the editor's clock, started, moved and stopped with the transport. Where there is no native side it is silent.
import 'package:flutter/services.dart';

class Soundtrack {
  static const _channel = MethodChannel('fotufilm/soundtrack');

  /// The movie whose sound plays next, or none.
  Future<void> load(String? path) => _call('load', {'path': path});

  /// Plays from `time` seconds at `rate`, from wherever it was.
  Future<void> play(double time, {double rate = 1, bool muted = false}) =>
      _call('play', {'time': time, 'rate': rate, 'muted': muted});

  Future<void> pause() => _call('pause');
  Future<void> setMuted(bool muted) => _call('muted', {'muted': muted});

  Future<void> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } on MissingPluginException {
      // No native side on this platform: the movie plays silent.
    } on PlatformException {
      // A sound that cannot play leaves the pictures playing.
    }
  }
}
