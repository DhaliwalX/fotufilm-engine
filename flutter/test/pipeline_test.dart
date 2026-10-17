import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/model/pipeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Catalogue catalogue;
  setUpAll(() async => catalogue = await Catalogue.load());

  test('the walk follows the film’s own settings only', () {
    Json edit() => defaultEdit(catalogue, 'gold200');
    expect(hasProfileSettings(catalogue, edit()), isFalse);
    expect(hasProfileSettings(catalogue, edit()..['format'] = '135'), isTrue);
    expect(hasProfileSettings(catalogue, edit()..['filters'] = ['81a']), isTrue);
    expect(hasProfileSettings(catalogue, edit()..['profile'] = {'push': 0}), isFalse);
    expect(hasProfileSettings(catalogue, edit()..['profile'] = {'push': 1}), isTrue);
    expect(hasProfileSettings(catalogue, edit()..['profile'] = {'grainModel': 'clump'}), isFalse);
    // The halation return counts at any value, as in the web editor.
    expect(hasProfileSettings(catalogue, edit()..['profile'] = {'halationReturn': 0}), isTrue);
    expect(hasProfileSettings(catalogue, edit()..['profile'] = {'notAControl': 3}), isFalse);
  });

  test('a stage goes with the develop while the tool is open, and leaving it ends it', () {
    final editor = EditorModel(catalogue);
    final doc = PhotoDocument(
        path: 'a.png', handle: 1, width: 10, height: 10,
        history: History(defaultEdit(catalogue, 'gold200')));
    editor.documents.add(doc);
    editor.activeIndex = 0;
    final tool = editor.pipeline;
    editor.setPanel(Panel.pipeline);
    tool.setStage(3);
    tool.setDifference(true);
    expect(editor.renderOptions(doc), {'stage': 3, 'difference': true, 'printFrame': null});
    tool.setStage(null);
    expect(tool.difference, isFalse);
    expect(editor.renderOptions(doc), isEmpty);
    tool.setStage(2);
    editor.setPanel(Panel.light);
    expect(tool.stage, isNull);
    expect(editor.renderOptions(doc), isEmpty);
  });

  test('the stages are named as the inspector names them', () {
    final tool = EditorModel(catalogue).pipeline
      ..stages = [
        for (var i = 0; i < 11; i++) {'id': 's$i', 'label': 'Engine $i'},
      ];
    expect(tool.stageName(0), 'Bypass');
    expect(tool.stageName(9), 'Output');
    expect(tool.stageName(10), 'Engine 10');
  });
}
