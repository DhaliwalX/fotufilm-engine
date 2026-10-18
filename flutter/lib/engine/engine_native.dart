// The desktop engine: libfotufilm through dart:ffi. One isolate owns the engine and answers the
// editor's host calls in order, so the UI isolate never waits for a develop. A second isolate,
// started at the first export, makes the background calls on the same engine, so an export runs
// beside the editor's develops; a few more, started at the first thumbnail, draw thumbnails
// side by side.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine.dart';
import 'fotufilm_ffi.dart';

Future<EngineConnection> connect() => NativeEngine.start();

class NativeEngine implements EngineConnection {
  NativeEngine._(this._commands, this._address, this.capabilities, this.description);

  final SendPort _commands;

  /// The background calls' isolate, once an export has started it.
  Future<SendPort>? _lane;

  /// The isolates [callAside] spreads its calls over, with the calls each has in hand.
  Future<List<SendPort>>? _aside;
  late final List<int> _asideBusy;
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
  final _progress = <int, void Function(Map<String, dynamic>)>{};

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
    engine._answer(events);
    return engine;
  }

  /// Settles the calls an isolate answers, and passes on their progress.
  void _answer(StreamIterator<dynamic> events) async {
    while (await events.moveNext()) {
      final (int id, Object? result, TransferableTypedData? bytes) =
          events.current as (int, Object?, TransferableTypedData?);
      // A long call's progress, while it runs.
      if (result is (String,)) {
        _progress[id]?.call(jsonDecode(result.$1) as Map<String, dynamic>);
        continue;
      }
      _progress.remove(id);
      final completer = _pending.remove(id);
      if (completer == null) continue;
      if (result is String) {
        completer.complete(EngineReply(jsonDecode(result), bytes?.materialize().asUint8List()));
      } else if (result is (bool, String)) {
        completer.completeError(
            result.$1 ? const FotufilmCancelled() : FotufilmException(result.$2));
      }
    }
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
      false,
    ));
    return completer.future;
  }

  @override
  Future<EngineReply> callWithProgress(String method, Map<String, dynamic> params,
      void Function(Map<String, dynamic> progress) onProgress) {
    final id = _next++;
    final completer = _pending[id] = Completer<EngineReply>();
    _progress[id] = onProgress;
    _commands.send((id, method, jsonEncode(params), null, true));
    return completer.future;
  }

  /// Safe from any thread.
  @override
  void cancel() => FotufilmLibrary.open().cancel(Pointer<Void>.fromAddress(_address));

  @override
  bool get exportsInBackground => true;

  @override
  Future<EngineReply> callInBackground(String method, Map<String, dynamic> params,
      [void Function(Map<String, dynamic> progress)? onProgress]) async {
    final lane = await (_lane ??= _startLane());
    final id = _next++;
    final completer = _pending[id] = Completer<EngineReply>();
    if (onProgress != null) _progress[id] = onProgress;
    lane.send((id, method, jsonEncode({...params, 'background': true}), null, onProgress != null));
    return completer.future;
  }

  @override
  Future<EngineReply> callAside(String method, Map<String, dynamic> params) async {
    final lanes = await (_aside ??= _startAside());
    // The isolate with the fewest calls in hand.
    var lane = 0;
    for (var i = 1; i < lanes.length; i++) {
      if (_asideBusy[i] < _asideBusy[lane]) lane = i;
    }
    _asideBusy[lane]++;
    final id = _next++;
    final completer = _pending[id] = Completer<EngineReply>();
    lanes[lane].send((id, method, jsonEncode(params), null, false));
    try {
      return await completer.future;
    } finally {
      _asideBusy[lane]--;
    }
  }

  /// Half the cores, two to four: each thumbnail also spreads its own decode over the cores.
  Future<List<SendPort>> _startAside() async {
    final count = math.min(4, math.max(2, Platform.numberOfProcessors ~/ 2));
    _asideBusy = List.filled(count, 0);
    return Future.wait([for (var i = 0; i < count; i++) _startLane('fotufilm-thumbnails-$i')]);
  }

  Future<SendPort> _startLane([String name = 'fotufilm-exports']) async {
    final replies = ReceivePort();
    await Isolate.spawn(_serveLane, (replies.sendPort, _address), debugName: name);
    final events = StreamIterator(replies);
    await events.moveNext();
    final lane = events.current as SendPort;
    _answer(events);
    return lane;
  }

  /// A host call from the UI isolate: it only counts the cancel, so it never waits.
  @override
  void cancelBackground() =>
      FotufilmLibrary.open().call(Pointer<Void>.fromAddress(_address), 'cancelBackground', '{}');
}

/// A background or thumbnail isolate: the same engine, called from its own thread.
void _serveLane((SendPort, int) start) {
  final (replies, address) = start;
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  _answerCalls(FotufilmLibrary.open(), Pointer<Void>.fromAddress(address), commands, replies);
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
  _answerCalls(library, engine, commands, replies);
}

/// Makes each call that arrives on `commands`, in order, and sends back its answer.
void _answerCalls(
    FotufilmLibrary library, Pointer<Void> engine, ReceivePort commands, SendPort replies) {
  commands.listen((message) {
    final (int id, String method, String params, TransferableTypedData? bytes, bool reports) =
        message as (int, String, String, TransferableTypedData?, bool);
    // The engine reports on this thread while the call runs; each report goes straight back.
    final progress = reports
        ? NativeCallable<ProgressCallback>.isolateLocal(
            (Pointer<Void> _, Pointer<Utf8> json) => replies.send((id, (json.toDartString(),), null)))
        : null;
    try {
      final answer = library.call(
          engine, method, params, bytes?.materialize().asUint8List(), progress?.nativeFunction);
      replies.send((
        id,
        answer.json,
        answer.payload == null ? null : TransferableTypedData.fromList([answer.payload!]),
      ));
    } on FotufilmCancelled {
      replies.send((id, (true, 'Cancelled'), null));
    } catch (error) {
      replies.send((id, (false, '$error'), null));
    } finally {
      progress?.close();
    }
  });
}
