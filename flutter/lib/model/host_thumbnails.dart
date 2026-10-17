// Small pictures of files that are not open, drawn by the engine's `thumbnail` call from the file
// in place (Sources/FotufilmHost/HostService+Thumbnails.swift): a still's embedded or reduced
// preview, a movie's first frame. The library's tiles and the strip's waiting photos show them.
// One is drawn at a time, the newest request first, as the library's thumbnail queue does
// (web/src/photo-library/thumbnails.js), and only while someone still wants it.
import 'dart:async';
import 'dart:ui' as ui;

import '../engine/engine.dart';
import 'renderer.dart' show decodePng;

class HostThumbnails {
  HostThumbnails(this._engine);

  final EngineConnection? Function() _engine;

  /// Pictures kept for tiles that scrolled away, the least recently shown dropped first.
  static const retained = 600;
  final _cache = <String, ui.Image>{};
  final Set<String> _none = {};
  final List<_Job> _queue = [];
  final Map<String, _Job> _waiting = {};
  bool _running = false;

  /// What a file's picture is kept under: its path, size and date, so a replaced file is drawn
  /// again.
  static String keyOf(String path, int maxEdge, [Object? stamp]) => '$path|$maxEdge|$stamp';

  /// The picture drawn already, if any.
  ui.Image? peek(String path, int maxEdge, [Object? stamp]) {
    final key = keyOf(path, maxEdge, stamp);
    final image = _cache.remove(key);
    if (image != null) _cache[key] = image;
    return image;
  }

  /// Whether the engine could not draw this file.
  bool failed(String path, int maxEdge, [Object? stamp]) =>
      _none.contains(keyOf(path, maxEdge, stamp));

  /// The file's picture, or null when the engine draws none. `wanted` is asked before drawing,
  /// so a tile that scrolled away costs nothing.
  Future<ui.Image?> request(String path,
      {required int maxEdge, Object? stamp, bool Function()? wanted}) {
    final key = keyOf(path, maxEdge, stamp);
    final cached = peek(path, maxEdge, stamp);
    if (cached != null) return Future.value(cached);
    if (_none.contains(key)) return Future.value(null);
    final job = _waiting[key];
    if (job != null) {
      job.wanted.add(wanted ?? () => true);
      // Asked again: it is on screen now, so it goes first.
      _queue
        ..remove(job)
        ..add(job);
      return job.done.future;
    }
    final next = _waiting[key] = _Job(key, path, maxEdge, wanted ?? () => true);
    _queue.add(next);
    _pump();
    return next.done.future;
  }

  /// Forgets a file's pictures (renamed or trashed).
  void forget(String path) {
    _cache.removeWhere((key, _) => key.startsWith('$path|'));
    _none.removeWhere((key) => key.startsWith('$path|'));
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeLast();
        _waiting.remove(job.key);
        if (!job.wanted.any((wanted) => wanted())) {
          job.done.complete(null);
          continue;
        }
        ui.Image? image;
        try {
          final engine = _engine();
          if (engine == null) throw StateError('No engine.');
          final answer =
              await engine.call('thumbnail', {'path': job.path, 'maxEdge': job.maxEdge});
          final bytes = answer.bytes('thumbnail');
          if (bytes != null) image = await decodePng(bytes);
        } catch (_) {
          image = null;
        }
        if (image == null) {
          _none.add(job.key);
        } else {
          _cache[job.key] = image;
          while (_cache.length > retained) {
            _cache.remove(_cache.keys.first);
          }
        }
        job.done.complete(image);
      }
    } finally {
      _running = false;
    }
  }
}

class _Job {
  _Job(this.key, this.path, this.maxEdge, bool Function() wanted) : wanted = [wanted];
  final String key, path;
  final int maxEdge;
  final List<bool Function()> wanted;
  final done = Completer<ui.Image?>();
}
