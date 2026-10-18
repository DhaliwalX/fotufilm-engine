// dart:ffi bindings for the engine's C interface, Sources/CFotufilmHost/include/fotufilm.h.
// Only the calls the editor needs: the engine's lifetime, the web editor's host calls, cancel.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine.dart';

const fotufilmOk = 0;
const fotufilmCancelled = 2;

final class FotufilmAnswer extends Struct {
  external Pointer<Utf8> json;
  external Pointer<Uint8> payload;
  @Size()
  external int payloadLength;
}

typedef _CapabilitiesC = Pointer<Utf8> Function();
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _CreateC = Pointer<Void> Function(Pointer<Pointer<Utf8>>);
typedef _DescribeC = Pointer<Utf8> Function(Pointer<Void>);
typedef _CancelC = Void Function(Pointer<Void>);
typedef CancelFunction = void Function(Pointer<Void>);
typedef _HostCallC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>,
    Size, Pointer<FotufilmAnswer>, Pointer<Pointer<Utf8>>);
typedef _HostCallDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>,
    int, Pointer<FotufilmAnswer>, Pointer<Pointer<Utf8>>);
typedef _HostCallProgressC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Void>, Size, Pointer<NativeFunction<ProgressCallback>>, Pointer<Void>,
    Pointer<FotufilmAnswer>, Pointer<Pointer<Utf8>>);
typedef _HostCallProgressDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Void>, int, Pointer<NativeFunction<ProgressCallback>>, Pointer<Void>,
    Pointer<FotufilmAnswer>, Pointer<Pointer<Utf8>>);

/// `fotufilm_progress_callback`: a long call's progress as JSON, on the calling thread.
typedef ProgressCallback = Void Function(Pointer<Void> context, Pointer<Utf8> json);
typedef _AnswerFreeC = Void Function(Pointer<FotufilmAnswer>);
typedef _AnswerFreeDart = void Function(Pointer<FotufilmAnswer>);

/// The loaded `libfotufilm`. The app carries it in Contents/Frameworks, beside Flutter's own;
/// `FOTUFILM_LIBRARY` names another build for development.
class FotufilmLibrary {
  FotufilmLibrary._(DynamicLibrary lib)
      : _capabilities = lib.lookupFunction<_CapabilitiesC, _CapabilitiesC>('fotufilm_capabilities'),
        _free = lib.lookupFunction<_FreeC, _FreeDart>('fotufilm_free'),
        _create = lib.lookupFunction<_CreateC, _CreateC>('fotufilm_engine_create'),
        _describe = lib.lookupFunction<_DescribeC, _DescribeC>('fotufilm_engine_describe'),
        cancel = lib.lookupFunction<_CancelC, CancelFunction>('fotufilm_engine_cancel'),
        _hostCall = lib.lookupFunction<_HostCallC, _HostCallDart>('fotufilm_host_call'),
        _hostCallProgress = lib.lookupFunction<_HostCallProgressC, _HostCallProgressDart>(
            'fotufilm_host_call_progress'),
        _answerFree = lib.lookupFunction<_AnswerFreeC, _AnswerFreeDart>('fotufilm_answer_free');

  static FotufilmLibrary? _shared;

  static FotufilmLibrary open() => _shared ??= FotufilmLibrary._(DynamicLibrary.open(_path()));

  static String _path() {
    final override = Platform.environment['FOTUFILM_LIBRARY'];
    if (override != null && override.isNotEmpty) return override;
    final exe = File(Platform.resolvedExecutable).parent;
    // <bundle>/fotufilm → <bundle>/lib/libfotufilm.so (linux/CMakeLists.txt)
    if (Platform.isLinux) return '${exe.path}/lib/libfotufilm.so';
    // Contents/MacOS/<app> → Contents/Frameworks/libfotufilm.dylib
    return '${exe.parent.path}/Frameworks/libfotufilm.dylib';
  }

  final _CapabilitiesC _capabilities;
  final _FreeDart _free;
  final _CreateC _create;
  final _DescribeC _describe;
  final CancelFunction cancel;
  final _HostCallDart _hostCall;
  final _HostCallProgressDart _hostCallProgress;
  final _AnswerFreeDart _answerFree;

  String _take(Pointer<Utf8> string) {
    if (string == nullptr) return '';
    final value = string.toDartString();
    _free(string);
    return value;
  }

  String capabilities() => _take(_capabilities());

  Pointer<Void> createEngine() {
    final error = calloc<Pointer<Utf8>>();
    try {
      final engine = _create(error);
      if (engine == nullptr) throw FotufilmException(_take(error.value));
      return engine;
    } finally {
      calloc.free(error);
    }
  }

  String describe(Pointer<Void> engine) => _take(_describe(engine));

  /// One host call: JSON in, JSON and an optional payload out. Runs on the calling thread
  /// until the engine answers, so the editor makes it from the engine isolate. `progress`, an
  /// isolate-local callable, hears a long call's progress on this thread while it runs.
  HostAnswer call(Pointer<Void> engine, String method, String params, [List<int>? payload,
      Pointer<NativeFunction<ProgressCallback>>? progress]) {
    final methodC = method.toNativeUtf8();
    final paramsC = params.toNativeUtf8();
    final answer = calloc<FotufilmAnswer>();
    final error = calloc<Pointer<Utf8>>();
    Pointer<Uint8> bytes = nullptr;
    try {
      if (payload != null && payload.isNotEmpty) {
        bytes = malloc<Uint8>(payload.length);
        bytes.asTypedList(payload.length).setAll(0, payload);
      }
      final status = progress == null
          ? _hostCall(engine, methodC, paramsC, bytes.cast(), payload?.length ?? 0, answer, error)
          : _hostCallProgress(engine, methodC, paramsC, bytes.cast(), payload?.length ?? 0,
              progress, nullptr, answer, error);
      if (status == fotufilmCancelled) throw const FotufilmCancelled();
      if (status != fotufilmOk) throw FotufilmException(_take(error.value));
      final json = answer.ref.json == nullptr ? '{}' : answer.ref.json.toDartString();
      final length = answer.ref.payloadLength;
      final data =
          length == 0 ? null : Uint8List.fromList(answer.ref.payload.asTypedList(length));
      _answerFree(answer);
      return HostAnswer(json, data);
    } finally {
      malloc.free(methodC);
      malloc.free(paramsC);
      if (bytes != nullptr) malloc.free(bytes);
      calloc.free(answer);
      calloc.free(error);
    }
  }
}

class HostAnswer {
  HostAnswer(this.json, this.payload);
  final String json;
  final Uint8List? payload;
}
