// Small pictures of files that are not open, drawn by the engine's `thumbnail` call from the file
// in place (Sources/FotufilmHost/HostService+Thumbnails.swift): a still's embedded or reduced
// preview, a movie's first frame. The library's tiles and the strip's waiting photos show them.
// A few are drawn at once beside the editor's develops (`callAside`), the newest request first,
// and only while someone still wants them. They arrive as pixels, so nothing is encoded or
// decoded twice.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/engine.dart';

class HostThumbnails {
  HostThumbnails(this._engine);

  final EngineConnection? Function() _engine;

  /// Pictures kept for tiles that scrolled away, the least recently shown dropped first.
  static const retained = 600;
  final _cache = <String, ui.Image>{};
  final Set<String> _none = {};
  final List<_Job> _queue = [];
  final Map<String, _Job> _waiting = {};

  /// Thumbnails drawn at once: enough to keep every thumbnail isolate busy.
  static const parallel = 6;
  int _running = 0;

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

  void _pump() {
    while (_running < parallel && _queue.isNotEmpty) {
      final job = _queue.removeLast();
      _waiting.remove(job.key);
      if (!job.wanted.any((wanted) => wanted())) {
        job.done.complete(null);
        continue;
      }
      _running++;
      _draw(job).then((image) {
        if (image == null) {
          _none.add(job.key);
        } else {
          _cache[job.key] = image;
          while (_cache.length > retained) {
            _cache.remove(_cache.keys.first);
          }
        }
        job.done.complete(image);
      }).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }

  Future<ui.Image?> _draw(_Job job) async {
    try {
      final engine = _engine();
      if (engine == null) return null;
      final answer = await engine
          .callAside('thumbnail', {'path': job.path, 'maxEdge': job.maxEdge, 'pixels': true});
      final pixels = answer.bytes('thumbnail');
      final width = (answer.json['width'] as num?)?.toInt() ?? 0;
      final height = (answer.json['height'] as num?)?.toInt() ?? 0;
      if (pixels == null || width <= 0 || height <= 0) return null;
      return await _image(pixels, width, height);
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image> _image(Uint8List rgba, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }
}

class _Job {
  _Job(this.key, this.path, this.maxEdge, bool Function() wanted) : wanted = [wanted];
  final String key, path;
  final int maxEdge;
  final List<bool Function()> wanted;
  final done = Completer<ui.Image?>();
}
