import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/engine/engine.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';

/// An engine whose background calls answer when the test says.
class _Engine implements EngineConnection {
  final background = <(String, Map<String, dynamic>, Completer<EngineReply>)>[];
  final calls = <(String, Map<String, dynamic>)>[];
  var cancelledBackground = 0;

  @override
  Future<EngineReply> call(String method,
      [Map<String, dynamic> params = const {}, Uint8List? payload]) async {
    calls.add((method, params));
    return EngineReply(<String, dynamic>{}, null);
  }

  @override
  Future<EngineReply> callWithProgress(String method, Map<String, dynamic> params,
          void Function(Map<String, dynamic> progress) onProgress) =>
      call(method, params);

  @override
  Future<EngineReply> callInBackground(String method, Map<String, dynamic> params,
      [void Function(Map<String, dynamic> progress)? onProgress]) {
    final answer = Completer<EngineReply>();
    background.add((method, params, answer));
    return answer.future;
  }

  @override
  void cancel() {}

  @override
  void cancelBackground() {
    cancelledBackground++;
    background.last.$3.completeError(const FotufilmCancelled());
  }
  @override
  Future<EngineReply> callAside(String method, Map<String, dynamic> params) =>
      call(method, params);

  @override
  bool get exportsInBackground => true;
  @override
  Map<String, dynamic> get capabilities => const {'batchExport': true};
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

  PhotoDocument photo(String path, int handle) => PhotoDocument(
        path: path,
        handle: handle,
        width: 600,
        height: 400,
        history: History(defaultEdit(editor.catalogue)),
      );

  setUp(() async {
    editor = EditorModel(await Catalogue.load());
    engine = _Engine();
    editor.engine = engine;
    editor.documents.addAll([photo('/roll/a.png', 1), photo('/roll/b.png', 2)]);
    editor.activeIndex = 0;
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('an export runs in the background with the edit it was asked for', () async {
    var started = false;
    final saved = editor.exporter.exportPhoto(path: '/out/a.png', onStarted: () => started = true);
    await settle();
    expect(started, isTrue);
    expect(editor.exporter.busy, isTrue);
    expect(editor.exporting, isFalse, reason: 'the editor keeps editing');

    // Editing after asking changes nothing in the export.
    editor.change({'ev': 1.5});
    final (method, params, answer) = engine.background.single;
    expect(method, 'export');
    expect((params['edit'] as Map)['ev'], isNot(1.5));

    answer.complete(EngineReply(<String, dynamic>{'path': '/out/a.png'}, null));
    expect((await saved)?.path, '/out/a.png');
    expect(editor.exporter.busy, isFalse);
    expect(editor.exporter.saved?.path, '/out/a.png');
  });

  test('exports wait their turn, and one waiting can be cancelled before it starts', () async {
    final first = editor.exporter.exportPhoto(path: '/out/a.png');
    await settle();
    editor.selectDocument(1);
    final second = editor.exporter.exportPhoto(path: '/out/b.png');
    await settle();
    expect(editor.exporter.jobs.length, 2);
    expect(engine.background.length, 1, reason: 'the second waits for the first');

    editor.exporter.cancelJob(editor.exporter.jobs.last);
    expect(await second, isNull);
    editor.exporter.cancelJob(editor.exporter.jobs.single);
    expect(engine.cancelledBackground, 1);
    expect(await first, isNull);
    expect(editor.exporter.busy, isFalse);
  });

  test('a photograph closed while it exports is let go when the export is done', () async {
    final saved = editor.exporter.exportPhoto(path: '/out/a.png');
    await settle();
    await editor.closeDocument(0);
    expect(engine.calls.where((c) => c.$1 == 'release'), isEmpty);

    engine.background.single.$3.complete(EngineReply(<String, dynamic>{}, null));
    await saved;
    await settle();
    expect(engine.calls.where((c) => c.$1 == 'release').single.$2['handle'], 1);
  });
}
