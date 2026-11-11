import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/engine/engine.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/editor.dart';

/// A one-pixel picture, as the engine would answer a develop with.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

/// An engine that opens any file, names it by its contents, and develops a one-pixel picture.
class _Engine implements EngineConnection {
  final released = <int>[];
  final imported = <String>[];
  var handles = 0, renders = 0;

  /// Develops to cancel before one is answered, as the renderer does for a newer edit.
  var cancelling = 0;

  @override
  Future<EngineReply> call(String method,
      [Map<String, dynamic> params = const {}, Uint8List? payload]) async {
    switch (method) {
      case 'release':
        released.add(params['handle'] as int);
      case 'importPath':
        final path = params['path'] as String;
        imported.add(path);
        return EngineReply(<String, dynamic>{
          'handle': ++handles,
          'naturalWidth': 600,
          'naturalHeight': 400,
          'identity': File(path).readAsStringSync(),
          if (path.endsWith('.mov')) 'video': {'start': 0, 'duration': 2, 'frameRate': 24},
          // The picture shown while the photograph first develops.
          'payloads': {
            'preview': [0, _png.length]
          }
        }, _png);
      case 'render':
        if (cancelling > 0) {
          cancelling--;
          throw const FotufilmCancelled();
        }
        renders++;
        return EngineReply(<String, dynamic>{
          'payloads': {
            'preview': [0, _png.length]
          }
        }, _png);
    }
    return EngineReply(<String, dynamic>{}, null);
  }

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
  Future<EngineReply> callAside(String method, Map<String, dynamic> params) =>
      call(method, params);
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
  late Catalogue catalogue;
  late Directory scratch;
  late AppSettings settings;
  late EditorModel editor;
  late _Engine engine;

  setUpAll(() async => catalogue = await Catalogue.load());

  /// The app, started on the gallery kept so far; again for a relaunch.
  EditorModel launch({bool phone = true}) {
    engine = _Engine();
    return EditorModel(catalogue, settings: settings, galleryFolder: '${scratch.path}/gallery')
      ..engine = engine
      ..gallery.phone = phone;
  }

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('gallery-test');
    settings = AppSettings.memory();
    editor = launch();
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  Gallery gallery() => editor.gallery;

  /// A file picked from elsewhere on the device; its contents are its identity.
  PhotoFile picked(String name, {String? contents}) {
    final file = File('${scratch.path}/picked/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents ?? name);
    return PhotoFile(name, path: file.path);
  }

  Future<void> edit(double ev) async {
    editor
      ..setParam('ev', ev)
      ..endEdit();
    await gallery().keep();
  }

  /// Opens a picked photograph, edits it and goes back to the gallery.
  Future<GalleryEntry> keepPhoto(String name, {double ev = 0.5}) async {
    await editor.openFiles([picked(name)]);
    await edit(ev);
    await gallery().closeEditor();
    return gallery().entries.firstWhere((e) => e.name == name);
  }

  Future<GalleryEntry> keepScan(String name) async {
    await editor.openFiles([picked(name)], negative: true);
    await gallery().closeEditor();
    return gallery().entries.firstWhere((e) => e.name == name);
  }

  test('a photograph opened and closed untouched leaves nothing behind', () async {
    expect(gallery().shown, isTrue);
    await editor.openFiles([picked('a.jpg')]);
    expect(gallery().shown, isFalse);

    await gallery().closeEditor();
    expect(gallery().shown, isTrue);
    expect(gallery().entries, isEmpty);
    expect(editor.documents, isEmpty);
    expect(engine.released, [1]);
    expect(Directory('${scratch.path}/gallery').existsSync(), isFalse);
  });

  test('a photograph joins with its first edit, as a copy with a developed picture', () async {
    await editor.openFiles([picked('a.jpg')]);
    await edit(0.5);

    final entry = gallery().entries.single;
    expect(entry.name, 'a.jpg');
    expect(entry.negative, isFalse);
    expect(entry.video, isFalse);
    expect(File(gallery().pathOf(entry)).readAsStringSync(), 'a.jpg');
    expect(File('${scratch.path}/gallery/entries/${entry.id}.png').readAsBytesSync(), _png);
    expect(gallery().picture(entry), isNotNull);
    // The picked file stays where it was: the engine is reading it.
    expect(File('${scratch.path}/picked/a.jpg').existsSync(), isTrue);

    // A later edit moves it on and develops its picture again; no change does neither.
    final first = entry.modified;
    await edit(1);
    await gallery().keep();
    expect(gallery().entries.single.modified, greaterThan(first));
    expect(engine.renders, 2);

    // The gallery is there when the app starts again.
    editor = launch();
    expect(gallery().entries.single.id, entry.id);
    expect(gallery().entries.single.modified, greaterThan(first));
  });

  test('an edit undone back to how the photograph opened does not join it', () async {
    await editor.openFiles([picked('a.jpg')]);
    editor
      ..setParam('ev', 1)
      ..endEdit()
      ..undo();
    await gallery().closeEditor();
    expect(gallery().entries, isEmpty);
  });

  test('closing the editor keeps what was edited and closes every photograph', () async {
    await editor.openFiles([picked('a.jpg'), picked('b.jpg')]);
    editor
      ..setParam('ev', 1)
      ..endEdit();
    // The develop is cancelled for a newer edit, and asked for again.
    engine.cancelling = 2;
    await gallery().closeEditor();

    expect(gallery().entries.single.name, 'b.jpg');
    expect(engine.renders, 1);
    expect(editor.documents, isEmpty);
    expect(engine.released, unorderedEquals([1, 2]));
    expect(gallery().shown, isTrue);
    expect(gallery().closing, isFalse);
  });

  test('the last photograph closed is kept, and the gallery is back', () async {
    await editor.openFiles([picked('a.jpg'), picked('b.jpg')]);
    editor
      ..setParam('ev', 0.5)
      ..endEdit();
    await editor.strip.close(editor.strip.items.last);
    final kept = gallery().entries.single;
    expect(kept.name, 'b.jpg');
    expect(File('${scratch.path}/gallery/entries/${kept.id}.png').existsSync(), isTrue);
    expect(gallery().shown, isFalse);

    await editor.strip.close(editor.strip.items.single);
    expect(gallery().entries, [kept]);
    expect(gallery().shown, isTrue);
    expect(settings.get<String>('gallery.open'), isNull);
  });

  test('a scanned negative joins as it opens, and a movie is marked as one', () async {
    await editor.openFiles([picked('scan.dng')], negative: true);
    await gallery().closeEditor();
    final scan = gallery().entries.single;
    expect(scan.negative, isTrue);
    expect(gallery().looseScans, [scan]);
    expect(gallery().photos, isEmpty);
    expect(gallery().tabbed, isFalse);

    final movie = await keepPhoto('clip.mov');
    expect(movie.video, isTrue);
    expect(gallery().photos, [movie]);
    expect(gallery().tabbed, isTrue);
    expect(gallery().tab, GalleryTab.photos);
  });

  test('the most recently edited comes first', () async {
    final a = await keepPhoto('a.jpg');
    final b = await keepPhoto('b.jpg');
    expect(gallery().entries, [b, a]);

    await gallery().open(a);
    await edit(1.5);
    await gallery().closeEditor();
    expect(gallery().entries, [a, b]);
  });

  test('an entry opens from its own copy, where its edit was left', () async {
    final entry = await keepPhoto('a.jpg', ev: 0.75);
    File('${scratch.path}/picked/a.jpg').deleteSync();

    await gallery().open(entry);
    expect(engine.imported.last, gallery().pathOf(entry));
    expect(gallery().shown, isFalse);
    expect((editor.edit['params'] as Map)['ev'], 0.75);

    // Editing it again adds no second entry.
    await edit(1);
    await gallery().closeEditor();
    expect(gallery().entries, [entry]);
  });

  test('a photograph picked again is the entry it already is', () async {
    final entry = await keepPhoto('a.jpg');
    await editor.openFiles([picked('copy.jpg', contents: 'a.jpg')]);
    expect((editor.edit['params'] as Map)['ev'], 0.5);
    await edit(2);
    await gallery().closeEditor();
    expect(gallery().entries, [entry]);
  });

  test('an entry whose file has gone says so and stays in the gallery', () async {
    final entry = await keepPhoto('a.jpg');
    File(gallery().pathOf(entry)).deleteSync();
    await gallery().open(entry);
    expect(editor.error, 'a.jpg is no longer on this device.');
    expect(gallery().shown, isTrue);
  });

  test('deleting removes the file, the picture and the kept edit', () async {
    final entry = await keepPhoto('a.jpg');
    final file = File(gallery().pathOf(entry));
    expect(settings.get<String>('keptEdit:a.jpg'), isNotNull);

    await gallery().delete(entry);
    expect(gallery().entries, isEmpty);
    expect(file.existsSync(), isFalse);
    expect(file.parent.existsSync(), isFalse);
    expect(Directory('${scratch.path}/gallery/entries').listSync(), isEmpty);
    expect(settings.get<String>('keptEdit:a.jpg'), isNull);
  });

  test('the app comes back to the photograph it was closed on', () async {
    final entry = await keepPhoto('a.jpg');
    await gallery().open(entry);

    editor = launch();
    expect(gallery().shown, isFalse);
    await gallery().restore();
    expect(editor.active?.path, gallery().pathOf(gallery().entries.single));
    expect(gallery().shown, isFalse);

    // Closed from the editor, it starts on the gallery.
    await gallery().closeEditor();
    editor = launch();
    expect(gallery().shown, isTrue);
    await gallery().restore();
    expect(editor.documents, isEmpty);
  });

  test('a photograph deleted since is not come back to', () async {
    final entry = await keepPhoto('a.jpg');
    await gallery().open(entry);
    File(gallery().pathOf(entry)).deleteSync();

    editor = launch();
    await gallery().restore();
    expect(gallery().shown, isTrue);
    expect(editor.documents, isEmpty);
  });

  test('rolls hold negatives: a frame is filed in the roll\'s folder', () async {
    final first = await keepScan('1.dng');
    final second = await keepScan('2.dng');
    final roll = gallery().createRoll(' Gold 200, Montreal ', DateTime(2026, 10, 23));
    expect(roll.name, 'Gold 200, Montreal');
    expect(gallery().tab, GalleryTab.negatives);

    await gallery().fileIn(first, roll);
    await gallery().fileIn(second, roll);
    expect(gallery().framesOf(roll), [first, second]);
    expect(gallery().looseScans, isEmpty);
    expect(first.file, 'rolls/${roll.id}/1.dng');
    expect(File(gallery().pathOf(first)).existsSync(), isTrue);
    expect(Directory('${scratch.path}/gallery/photos/${first.id}').existsSync(), isFalse);

    // A frame opens alone: the roll's others are chosen in the gallery.
    await gallery().open(second);
    expect(editor.active?.path, gallery().pathOf(second));
    expect(editor.strip.items.single.name, '2.dng');
    await gallery().closeEditor();
    expect(editor.strip.items, isEmpty);

    // Rolls and their frames are there when the app starts again, and a frame it was closed on
    // comes back with its roll behind it.
    await gallery().open(second);
    editor = launch();
    await gallery().restore();
    final kept = gallery().rolls.single;
    expect(kept.name, 'Gold 200, Montreal');
    expect(kept.day, DateTime(2026, 10, 23));
    expect([for (final frame in gallery().framesOf(kept)) frame.name], ['1.dng', '2.dng']);
    expect(editor.active?.name, '2.dng');
    expect(gallery().rollOpen, kept);
    await gallery().closeEditor();

    // Taken out, a frame is a loose scan again.
    final frame = gallery().framesOf(kept).first;
    await gallery().fileIn(frame, null);
    expect(gallery().looseScans, [frame]);
    expect(frame.file, 'photos/${frame.id}/1.dng');
    expect(File(gallery().pathOf(frame)).existsSync(), isTrue);
  });

  test('scans chosen for a roll join it; a photograph does not', () async {
    final roll = gallery().createRoll('Roll', DateTime(2026, 11, 1));
    await gallery().addFrames(
        roll, () => editor.openFiles([picked('1.dng'), picked('2.dng')], negative: true));
    await gallery().closeEditor();
    expect([for (final frame in gallery().framesOf(roll)) frame.name], ['1.dng', '2.dng']);

    await keepPhoto('a.jpg');
    expect(gallery().framesOf(roll).length, 2);
    expect(gallery().photos.single.roll, isNull);
  });

  test('a roll is deleted with its frames or without them', () async {
    final one = gallery().createRoll('One', DateTime(2026, 11, 1));
    final two = gallery().createRoll('Two', DateTime(2026, 11, 2));
    expect(gallery().rolls, [two, one]);
    final a = await keepScan('a.dng');
    final b = await keepScan('b.dng');
    await gallery().fileIn(a, one);
    await gallery().fileIn(b, two);

    await gallery().deleteRoll(one, frames: false);
    expect(gallery().rolls, [two]);
    expect(gallery().looseScans, [a]);
    expect(File(gallery().pathOf(a)).existsSync(), isTrue);
    expect(Directory('${scratch.path}/gallery/rolls/${one.id}').existsSync(), isFalse);

    final file = File(gallery().pathOf(b));
    await gallery().deleteRoll(two, frames: true);
    expect(gallery().rolls, isEmpty);
    expect(gallery().entries, [a]);
    expect(file.existsSync(), isFalse);
  });

  test('a roll keeps its new name and date, and the latest shot comes first', () async {
    final one = gallery().createRoll('One', DateTime(2026, 11, 1));
    final two = gallery().createRoll('Two', DateTime(2026, 11, 2));
    gallery().updateRoll(one, name: 'Renamed', date: DateTime(2026, 11, 3));
    expect(gallery().rolls, [one, two]);

    editor = launch();
    expect([for (final roll in gallery().rolls) roll.name], ['Renamed', 'Two']);
  });

  test('only a phone keeps a gallery', () async {
    editor = launch(phone: false);
    expect(gallery().available, isFalse);
    expect(gallery().shown, isFalse);
    await editor.openFiles([picked('a.jpg')]);
    await edit(1);
    await gallery().closeEditor();
    expect(gallery().entries, isEmpty);
    expect(editor.documents, hasLength(1));
  });
}
