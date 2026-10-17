import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/engine/engine.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/editor.dart';

/// An engine whose imports answer when the test says, or fail while `failing`.
class _Engine implements EngineConnection {
  final imports = <(String, Completer<EngineReply>)>[];
  final released = <int>[];
  var failing = false;
  var handles = 0;

  @override
  Future<EngineReply> call(String method,
      [Map<String, dynamic> params = const {}, Uint8List? payload]) async {
    if (method == 'release') released.add(params['handle'] as int);
    if (method != 'importPath') return EngineReply(<String, dynamic>{}, null);
    if (failing) throw FotufilmException('The file is damaged.');
    final answer = Completer<EngineReply>();
    imports.add((params['path'] as String, answer));
    return answer.future;
  }

  void answer() => imports.last.$2.complete(EngineReply(
      <String, dynamic>{'handle': ++handles, 'naturalWidth': 600, 'naturalHeight': 400}, null));

  @override
  Future<EngineReply> callWithProgress(String method, Map<String, dynamic> params,
          void Function(Map<String, dynamic> progress) onProgress) =>
      call(method, params);

  @override
  Future<EngineReply> callInBackground(String method, Map<String, dynamic> params,
          [void Function(Map<String, dynamic> progress)? onProgress]) =>
      call(method, params);

  @override
  void cancel() {}
  @override
  void cancelBackground() {}
  @override
  bool get exportsInBackground => false;
  @override
  Map<String, dynamic> get capabilities => const {};
  @override
  int? get address => null;
  @override
  bool get picturesAreDisplayP3 => true;
  @override
  bool get opensPaths => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorModel editor;
  late _Engine engine;

  PhotoFile file(String name) => PhotoFile(name, path: '/roll/$name');
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    editor = EditorModel(await Catalogue.load());
    engine = _Engine();
    editor.engine = engine;
  });

  test('a photograph that could not be opened is opened again by Retry', () async {
    engine.failing = true;
    await editor.openFiles([file('a.jpg')]);
    expect(editor.error, contains('a.jpg could not be opened'));
    expect(editor.canRetry, isTrue);

    engine.failing = false;
    editor.retry();
    expect(editor.error, isNull);
    await settle();
    engine.answer();
    await settle();
    await settle();
    expect(editor.documents.single.path, '/roll/a.jpg');
  });

  test('another message drops the Retry', () async {
    engine.failing = true;
    await editor.openFiles([file('a.jpg')]);
    editor.showError('The film could not be installed.');
    expect(editor.canRetry, isFalse);
  });

  test('Cancel stops opening after the file being read, which is let go', () async {
    final opening = editor.openFiles([file('a.jpg'), file('b.jpg')]);
    await settle();
    expect(editor.importing, isTrue);
    editor.cancelImport();
    expect(editor.status, isNull);

    engine.answer();
    await opening;
    expect(engine.imports.length, 1, reason: 'b.jpg is never read');
    expect(engine.released, [1]);
    expect(editor.documents, isEmpty);
  });
}
