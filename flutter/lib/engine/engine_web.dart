// The browser engine: the web editor's WASM and WebGPU engine, reached through the bridge
// web/src/flutter-bridge.js installs as `globalThis.fotufilmEngine`. It answers the same host
// calls the native engine does. The browser runs the develops off the page's thread itself.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'engine.dart';

@JS('fotufilmEngine')
external _Bridge? get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<_Answer> call(JSString method, JSString params, JSUint8Array? payload);
  external void cancel();
}

extension type _Answer(JSObject _) implements JSObject {
  external JSString? get json;
  external JSUint8Array? get payload;
  external JSString? get error;
  external JSBoolean? get cancelled;
}

Future<EngineConnection> connect() async {
  // The bridge is a module script that loads beside Flutter's; wait for it.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (_bridge == null) {
    if (DateTime.now().isAfter(deadline)) {
      throw FotufilmException('The browser engine did not load.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return WebEngine._(_bridge!);
}

class WebEngine implements EngineConnection {
  WebEngine._(this._engine);
  final _Bridge _engine;

  @override
  int? get address => null;

  @override
  bool get picturesAreDisplayP3 => false;

  @override
  bool get opensPaths => false;

  @override
  Map<String, dynamic> get capabilities => const {};

  @override
  Future<EngineReply> call(String method,
      [Map<String, dynamic> params = const {}, Uint8List? payload]) async {
    final answer =
        await _engine.call(method.toJS, jsonEncode(params).toJS, payload?.toJS).toDart;
    final error = answer.error?.toDart;
    if (error != null) {
      throw answer.cancelled?.toDart == true
          ? const FotufilmCancelled()
          : FotufilmException(error);
    }
    return EngineReply(jsonDecode(answer.json!.toDart), answer.payload?.toDart);
  }

  /// The bridge reports no progress; the call answers when it is done.
  @override
  Future<EngineReply> callWithProgress(String method, Map<String, dynamic> params,
          void Function(Map<String, dynamic> progress) onProgress) =>
      call(method, params);

  @override
  void cancel() => _engine.cancel();
}
