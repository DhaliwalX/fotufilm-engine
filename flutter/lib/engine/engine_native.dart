// The desktop engine: libfotufilm through dart:ffi. One isolate owns the engine and answers the
// editor's host calls in order, as the CEF host's engine thread does, so the UI isolate never
// waits for a develop.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'engine.dart';
import 'fotufilm_ffi.dart';

Future<EngineConnection> connect() => NativeEngine.start();

class NativeEngine implements EngineConnection {
  NativeEngine._(this._commands, this._address, this.capabilities, this.description);

  final SendPort _commands;
  final int _address;
  @override
  final Map<String, dynamic> capabilities;
  final Map<String, dynamic> description;
  int _next = 0;

  @override
  int get address => _address;

  @override
  bool get picturesAreDisplayP3 => true;

  @override
  bool get opensPaths => true;
  final _pending = <int, Completer<EngineReply>>{};

  static Future<NativeEngine> start() async {
    final replies = ReceivePort();
    await Isolate.spawn(_serve, replies.sendPort, debugName: 'fotufilm-engine');
    final events = StreamIterator(replies);
    await events.moveNext();
    final hello = events.current;
    if (hello is String) throw FotufilmException(hello);
    final (SendPort commands, int address, String caps, String describe) =
        hello as (SendPort, int, String, String);
    final engine = NativeEngine._(commands, address, jsonDecode(caps) as Map<String, dynamic>,
        jsonDecode(describe) as Map<String, dynamic>);
    () async {
      while (await events.moveNext()) {
        final (int id, Object? result, TransferableTypedData? bytes) =
            events.current as (int, Object?, TransferableTypedData?);
        final completer = engine._pending.remove(id);
        if (completer == null) continue;
        if (result is String) {
          completer.complete(EngineReply(jsonDecode(result), bytes?.materialize().asUint8List()));
        } else if (result is (bool, String)) {
          completer.completeError(
              result.$1 ? const FotufilmCancelled() : FotufilmException(result.$2));
        }
      }
    }();
    return engine;
  }

  @override
  Future<EngineReply> call(String method, [Map<String, dynamic> params = const {},
      Uint8List? payload]) {
    final id = _next++;
    final completer = _pending[id] = Completer<EngineReply>();
    _commands.send((
      id,
      method,
      jsonEncode(params),
      payload == null ? null : TransferableTypedData.fromList([payload]),
    ));
    return completer.future;
  }

  /// Safe from any thread.
  @override
  void cancel() => FotufilmLibrary.open().cancel(Pointer<Void>.fromAddress(_address));
}

void _serve(SendPort replies) {
  final FotufilmLibrary library;
  final Pointer<Void> engine;
  try {
    library = FotufilmLibrary.open();
    engine = library.createEngine();
  } catch (error) {
    replies.send('$error');
    return;
  }
  final commands = ReceivePort();
  replies.send((commands.sendPort, engine.address, library.capabilities(),
      library.describe(engine)));
  commands.listen((message) {
    final (int id, String method, String params, TransferableTypedData? bytes) =
        message as (int, String, String, TransferableTypedData?);
    try {
      final answer = library.call(engine, method, params, bytes?.materialize().asUint8List());
      replies.send((
        id,
        answer.json,
        answer.payload == null ? null : TransferableTypedData.fromList([answer.payload!]),
      ));
    } on FotufilmCancelled {
      replies.send((id, (true, 'Cancelled'), null));
    } catch (error) {
      replies.send((id, (false, '$error'), null));
    }
  });
}
