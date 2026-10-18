// The engine, as the editor reaches it on any platform: host calls answered in order
// (fotufilm.h's `fotufilm_host_call`). A desktop build calls libfotufilm through dart:ffi on its
// own isolate (engine_native.dart); a browser build calls the web editor's WASM and WebGPU
// engine through a JavaScript bridge that answers the same calls (engine_web.dart,
// web/src/flutter-bridge.js).
import 'dart:typed_data';

import 'engine_web.dart' if (dart.library.io) 'engine_native.dart' as platform;

abstract interface class EngineConnection {
  /// A host call, answered in the order it was made.
  Future<EngineReply> call(String method,
      [Map<String, dynamic> params = const {}, Uint8List? payload]);

  /// A long host call (Export All) that reports its progress, `{progress, ...}`, as it runs.
  Future<EngineReply> callWithProgress(String method, Map<String, dynamic> params,
      void Function(Map<String, dynamic> progress) onProgress);

  /// Stops the develop in progress at its next opportunity.
  void cancel();

  /// Whether still exports run beside the editor's develops ([callInBackground]); otherwise
  /// one holds the engine until it is done.
  bool get exportsInBackground;

  /// A still export (`export`, `exportBatch`, `exportOriginal`) run beside the editor's develops:
  /// [cancel] leaves it going and [cancelBackground] stops it. Background calls are answered in
  /// the order they were made; [onProgress] hears a long one's progress.
  Future<EngineReply> callInBackground(String method, Map<String, dynamic> params,
      [void Function(Map<String, dynamic> progress)? onProgress]);

  /// Stops the background call in progress.
  void cancelBackground();

  /// A short call that keeps no state (`thumbnail`), made beside the editor's develops and
  /// exports, several at once; answers come as each is done.
  Future<EngineReply> callAside(String method, Map<String, dynamic> params);

  /// What the engine's platform services offer (`fotufilm_capabilities`): export formats, HDR,
  /// Export All, the clipboard, subject selection, film packs, plug-ins and updates. Empty where
  /// the engine does not say.
  Map<String, dynamic> get capabilities;

  /// The native `fotufilm_engine *`, for a platform presenter; null in a browser.
  int? get address;

  /// Whether pictures arrive in Display P3 (native) rather than sRGB (a browser).
  bool get picturesAreDisplayP3;

  /// Whether photographs open by path (`importPath`) rather than by their bytes (`importFile`).
  bool get opensPaths;
}

/// Starts this platform's engine.
Future<EngineConnection> connectEngine() => platform.connect();

class EngineReply {
  EngineReply(Object? answer, this.payload)
      : value = answer,
        json = answer is Map<String, dynamic> ? answer : const {};

  /// The answer as decoded: an object for most calls, but a bare list, number or null for a few
  /// (`stages`, `sampleScene`, `lensCatalogue`), which [json] reads as empty.
  final Object? value;
  final Map<String, dynamic> json;
  final Uint8List? payload;

  /// A named byte range of the payload ({"payloads": {"name": [offset, length]}}).
  Uint8List? bytes(String name) {
    final ranges = json['payloads'];
    if (payload == null || ranges is! Map || ranges[name] is! List) return null;
    final range = ranges[name] as List;
    final offset = (range[0] as num).toInt(), length = (range[1] as num).toInt();
    return Uint8List.sublistView(payload!, offset, offset + length);
  }
}

class FotufilmException implements Exception {
  FotufilmException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FotufilmCancelled implements Exception {
  const FotufilmCancelled();
  @override
  String toString() => 'Cancelled';
}
