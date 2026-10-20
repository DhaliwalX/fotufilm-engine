import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/model/selective.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Catalogue catalogue;
  setUpAll(() async => catalogue = await Catalogue.load());

  test('a new selection starts on the photograph’s own develop', () {
    final edit = defaultEdit(catalogue, 'gold200');
    (edit['params'] as Map)['ev'] = 0.5;
    (edit['params'] as Map)['gradeMidtonesWarmth'] = -0.2;
    final selection = newSelection(edit);
    expect(selection['kind'], 'color');
    expect(selection['sample'], isNull);
    expect(selection['range'], 0.25);
    expect(selection['softness'], 0.5);
    final params = selection['params'] as Map;
    expect(params.keys, selectionKeys);
    expect(params['ev'], 0.5);
    expect(params['gradeMidtonesWarmth'], -0.2);
    expect(params.containsKey('grain'), isFalse);
    expect(selection['localTone'], true);
    expect(selection['gradeSpace'], false);
  });

  test('a sample inside a print frame lands on the photograph, the border on nothing', () {
    expect(frameSamplePoint([0.3, 0.7], null), [0.3, 0.7]);
    // A 1000 × 800 sheet with the picture 800 × 600, 100 in from the left and 150 up.
    final plan = {
      'placement': {
        'size': {'width': 1000, 'height': 800},
        'image': {'x': 100, 'y': 150, 'width': 800, 'height': 600},
      },
    };
    final top = frameSamplePoint([0.1, 50 / 800], plan)!;
    expect(top[0], closeTo(0, 1e-9));
    expect(top[1], closeTo(0, 1e-9));
    final middle = frameSamplePoint([0.5, 0.4375], plan)!;
    expect(middle[0], closeTo(0.5, 1e-9));
    expect(middle[1], closeTo(0.5, 1e-9));
    expect(frameSamplePoint([0.05, 0.5], plan), isNull);
    // A film border showing the lower half of a photograph twice as tall: back on the whole of it.
    final cropped = frameSamplePoint([0.5, 0.4375], {
      ...plan,
      'cropFraction': {'x': 0, 'y': 0.5, 'width': 1, 'height': 0.5},
    })!;
    expect(cropped[0], closeTo(0.5, 1e-9));
    expect(cropped[1], closeTo(0.75, 1e-9));
  });

  test('the subjects are told as the catalogue words them', () {
    final texts = ['Finding subjects…', 'No subjects found.', 'One subject found.', '%d subjects found.'];
    expect(subjectsFound(texts, null), 'Finding subjects…');
    expect(subjectsFound(texts, 0), 'No subjects found.');
    expect(subjectsFound(texts, 1), 'One subject found.');
    expect(subjectsFound(texts, 3), '3 subjects found.');
  });

  test('the mask goes with the develop only while the tool is open, and ends when it closes', () {
    final editor = EditorModel(catalogue);
    final doc = PhotoDocument(
        path: 'a.png', handle: 1, width: 10, height: 10,
        history: History(defaultEdit(catalogue, 'gold200')));
    editor.documents.add(doc);
    editor.activeIndex = 0;
    final tool = editor.selective;
    editor.setPanel(Panel.selective);
    tool.setShowMask(true);
    tool.setSampling(true);
    expect(editor.renderOptions(doc), {'showMask': true});
    editor.setPanel(Panel.film);
    expect(editor.renderOptions(doc), isEmpty);
    expect(tool.showMask, isFalse);
    expect(tool.sampling, isFalse);
  });

  test('changing the selection keeps the rest of it, and Clear removes it', () {
    final editor = EditorModel(catalogue);
    editor.documents.add(PhotoDocument(
        path: 'a.png', handle: 1, width: 10, height: 10,
        history: History(defaultEdit(catalogue, 'gold200'))));
    editor.activeIndex = 0;
    final tool = editor.selective;
    tool.change({'kind': 'light'});
    tool.change({'range': 0.4}, group: 'selective-range');
    final selection = editor.edit['selective'] as Map;
    expect(selection['kind'], 'light');
    expect(selection['range'], 0.4);
    expect(selection['softness'], 0.5);
    tool.change({'params': {...selection['params'] as Map, 'ev': 1.0}});
    tool.matchPhotograph();
    expect(((editor.edit['selective'] as Map)['params'] as Map)['ev'], 0);
    tool.clear();
    expect(editor.edit['selective'], isNull);
  });
}
