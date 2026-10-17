// The engine thread. One isolate owns the engine and answers the editor's host calls in order,
// as the CEF host's engine thread does, so the UI isolate never waits for a develop.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'fotufilm_ffi.dart';

class EngineReply {
  EngineReply(this.json, this.payload);
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

class Engine {
  Engine._(this._commands, this._address, this.capabilities, this.description);

  final SendPort _commands;
  final int _address;
  final Map<String, dynamic> capabilities;
  final Map<String, dynamic> description;
  int _next = 0;

  /// The `fotufilm_engine *`, for a native presenter to be lent to it.
  int get address => _address;
  final _pending = <int, Completer<EngineReply>>{};

  static Future<Engine> start() async {
    final replies = ReceivePort();
    await Isolate.spawn(_serve, replies.sendPort, debugName: 'fotufilm-engine');
    final events = StreamIterator(replies);
    await events.moveNext();
    final hello = events.current;
    if (hello is String) throw FotufilmException(hello);
    final (SendPort commands, int address, String caps, String describe) =
        hello as (SendPort, int, String, String);
    final engine = Engine._(commands, address, jsonDecode(caps) as Map<String, dynamic>,
        jsonDecode(describe) as Map<String, dynamic>);
    () async {
      while (await events.moveNext()) {
        final (int id, Object? result, TransferableTypedData? bytes) =
            events.current as (int, Object?, TransferableTypedData?);
        final completer = engine._pending.remove(id);
        if (completer == null) continue;
        if (result is String) {
          completer.complete(EngineReply(jsonDecode(result) as Map<String, dynamic>,
              bytes?.materialize().asUint8List()));
        } else if (result is (bool, String)) {
          completer.completeError(
              result.$1 ? const FotufilmCancelled() : FotufilmException(result.$2));
        }
      }
    }();
    return engine;
  }

  /// A host call, answered on the engine isolate in the order it was made.
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

  /// Stops the develop in progress at its next opportunity. Safe from any thread.
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
