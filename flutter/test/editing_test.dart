import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/auto_adjust.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/document.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/edit_history.dart';
import 'package:fotufilm_flutter/model/edit_settings.dart';
import 'package:fotufilm_flutter/model/saved_edits.dart';
import 'package:fotufilm_flutter/model/settings.dart';
import 'package:fotufilm_flutter/model/strip_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Catalogue catalogue;
  final stocks = <Json>[
    {'id': 'gold200', 'name': 'Kodak Gold 200', 'media': [{'id': 'ra4'}], 'filmMedium': 'ra4'},
    {'id': 'portra400', 'name': 'Kodak Portra 400', 'media': <Json>[]},
  ];
  String? filmName(String? id) =>
      stocks.where((s) => s['id'] == id).firstOrNull?['name'] as String?;

  setUpAll(() async => catalogue = await Catalogue.load());

  Json withParam(Json edit, String key, num value) =>
      copyEdit(edit)..['params'] = {...edit['params'] as Map, key: value};

  group('edit history', () {
    test('names each step after what it changed, in the Mac app order', () {
      final opened = defaultEdit(catalogue);
      final film = copyEdit(opened)..['stock'] = 'gold200';
      final light = withParam(film, 'ev', 1);
      final colour = withParam(light, 'saturation', 1.2);
      final grain = copyEdit(colour)..['seed'] = 7;
      final crop = copyEdit(grain)..['rotation'] = 1;
      expect(historyTitle(opened, film, filmName), 'Kodak Gold 200');
      expect(historyTitle(film, opened, filmName), 'Normal');
      expect(historyTitle(film, light), 'Light');
      expect(historyTitle(light, colour), 'Color');
      expect(historyTitle(colour, grain), 'Grain Pattern');
      expect(historyTitle(grain, crop), 'Crop & Rotate');
      expect(historyTitle(crop, copyEdit(crop)), 'Edit');
      final profile = copyEdit(crop)..['profile'] = {'couplerReach': 1.5};
      expect(historyTitle(crop, profile), 'Couplers');
    });

    test('Undo and Redo say what they change; the timeline marks the step standing', () {
      final opened = defaultEdit(catalogue);
      final h = History(opened);
      expect(undoTitle(h), 'Undo');
      final light = withParam(opened, 'ev', .5);
      h.past.add(h.present);
      h.present = light;
      final film = copyEdit(light)..['stock'] = 'portra400';
      h.future.add(film);
      expect(undoTitle(h, filmName), 'Undo Light');
      expect(redoTitle(h, filmName), 'Redo Kodak Portra 400');
      final timeline = editTimeline(h, filmName);
      expect(timeline.titles, ['Opened', 'Light', 'Kodak Portra 400']);
      expect(timeline.index, 1);
    });
  });

  group('copy and paste settings', () {
    test('every edit key travels in a section, except the photograph’s own', () {
      expect(sectionOf(catalogue, 'stock'), 'filmStock');
      expect(sectionOf(catalogue, 'format'), 'filmStock');
      expect(sectionOf(catalogue, 'ev'), 'lightExposure');
      expect(sectionOf(catalogue, 'temperature'), 'lightBalance');
      expect(sectionOf(catalogue, 'crop'), 'frameGeometry');
      expect(sectionOf(catalogue, 'medium'), 'printPaper');
      expect(sectionOf(catalogue, 'seed'), isNull);
      expect(defaultSections(catalogue), isNot(contains('frameGeometry')));
    });

    test('pastes the chosen sections only, the profile section by section', () {
      final source = withParam(defaultEdit(catalogue, 'gold200'), 'ev', 1.5)
        ..['seed'] = 99
        ..['rotation'] = 2
        ..['profile'] = {'push': 1, 'grainMottle': 0.4};
      final target = withParam(defaultEdit(catalogue), 'saturation', 0.5)
        ..['profile'] = {'halation': 0.2, 'push': -1};
      final pasted = pasteSettings(
          catalogue, target, CopiedSettings(['filmStock', 'lightExposure', 'filmLab'], source));
      expect(pasted['stock'], 'gold200');
      expect((pasted['params'] as Map)['ev'], 1.5);
      expect((pasted['params'] as Map)['saturation'], 0.5);
      expect(pasted['seed'], 0);
      expect(pasted['rotation'], 0);
      expect(pasted['profile'], {'halation': 0.2, 'push': 1});
    });

    test('a new film keeps a medium only where it offers one', () {
      final source = defaultEdit(catalogue, 'portra400');
      final target = defaultEdit(catalogue, 'gold200')
        ..['medium'] = 'ra4'
        ..['mediumFollowsFilm'] = false;
      final pasted =
          pastedEdit(catalogue, target, CopiedSettings(['filmStock'], source), stocks);
      expect(pasted['stock'], 'portra400');
      expect(pasted['medium'], isNull);
    });

    test('an edit matching its film prints on each film’s own medium', () {
      final edit = defaultEdit(catalogue, 'portra400', 'endura');
      expect(edit['mediumFollowsFilm'], isTrue);
      expect(mediumOnFilm(edit, stocks.first), 'ra4');
      expect(mediumOnFilm(edit, null), isNull);
      // A medium chosen by hand stays where the next film offers it.
      final chosen = copyEdit(edit)
        ..['medium'] = 'ra4'
        ..['mediumFollowsFilm'] = false;
      expect(mediumOnFilm(chosen, stocks.first), 'ra4');
      expect(mediumOnFilm(chosen, stocks.last), isNull);
      final pasted = pastedEdit(catalogue, defaultEdit(catalogue, 'portra400'),
          CopiedSettings(['filmStock'], defaultEdit(catalogue, 'gold200', 'ra4')), stocks);
      expect(pasted['medium'], 'ra4');
    });

    test('a kept edit from before Match Film was the default keeps its medium', () {
      final kept = Map.of(defaultEdit(catalogue, 'gold200'))..remove('mediumFollowsFilm');
      final restored = restoreEdit(editText(kept), catalogue, stocks);
      expect(restored['mediumFollowsFilm'], isFalse);
      expect(restored['medium'], isNull);
    });

    test('Paste Settings is named for several photos', () {
      expect(pasteTitle(1), 'Paste Settings');
      expect(pasteTitle(3), 'Paste Settings to 3 Photos');
    });
  });

  group('strip selection', () {
    final keys = ['a', 'b', 'c', 'd'];
    test('Shift spans from the anchor, ⌘ toggles, the shown photo stays chosen', () {
      var s = Selection.start('b');
      s = pressedStrip(keys, 'b', s, 'd', range: true);
      expect(chosenKeys(keys, 'b', s), {'b', 'c', 'd'});
      s = pressedStrip(keys, 'b', s, 'c', toggle: true);
      expect(chosenKeys(keys, 'b', s), {'b', 'd'});
      // ⌘-click on the shown photo leaves the selection as it was.
      final same = pressedStrip(keys, 'b', s, 'b', toggle: true);
      expect(chosenKeys(keys, 'b', same), {'b', 'd'});
      // A plain click starts again.
      expect(chosenKeys(keys, 'a', pressedStrip(keys, 'b', s, 'a')), {'a'});
    });
  });

  group('presets and look files', () {
    test('names sort as a person reads them', () {
      final names = ['Look 10', 'look 2', 'Alpha', 'Look 1']..sort(compareNames);
      expect(names, ['Alpha', 'Look 1', 'look 2', 'Look 10']);
    });

    test('an import never replaces a preset, and skips one already here', () {
      var n = 0;
      String id() => '${n++}';
      final settings = CopiedSettings(['filmStock'], defaultEdit(catalogue, 'gold200'));
      final other = CopiedSettings(['lightExposure'], defaultEdit(catalogue));
      final (once, added) = mergePresets([], [('Warm', settings)], id);
      expect(added, 1);
      final (twice, again) = mergePresets(once, [('Warm', settings), ('Warm', other)], id);
      expect(again, 1);
      expect(twice.map((p) => p.name), ['Warm', 'Warm 2']);
    });

    test('a look file reads back what was written, without the photograph’s own', () {
      final edit = withParam(defaultEdit(catalogue, 'gold200'), 'ev', 0.7)..['seed'] = 1234;
      final preset = Preset('x', 'Gold / warm', CopiedSettings(['filmStock', 'lightExposure'], edit));
      expect(lookFileName([preset]), 'Gold warm.fotufilmlook');
      expect(lookFileName([preset, preset]), 'Fotufilm Presets.fotufilmlook');
      final looks = readLooks(lookText(catalogue, [preset]), catalogue, stocks);
      expect(looks.missing, isEmpty);
      final (name, settings) = looks.presets.single;
      expect(name, 'Gold / warm');
      expect(settings.sections, ['filmStock', 'lightExposure']);
      expect(settings.edit['seed'], 0);
      expect((settings.edit['params'] as Map)['ev'], 0.7);
      // Importing it again beside the preset it came from adds nothing.
      final plain = Preset('z', 'Gold / warm',
          CopiedSettings(['filmStock', 'lightExposure'], copyEdit(edit)..['seed'] = 0));
      final (_, again) = mergePresets([plain], looks.presets, () => 'y');
      expect(again, 0);
      // A film not installed is kept and named.
      final missing = readLooks(lookText(catalogue, [preset]), catalogue, [stocks[1]]);
      expect(missing.missing, [('Gold / warm', 'gold200')]);
      expect(() => readLooks('{}', catalogue, stocks), throwsA(isA<EditProblem>()));
    });
  });

  group('kept edits', () {
    test('an edit is kept as text and restored as it was', () {
      final edit = withParam(defaultEdit(catalogue, 'gold200'), 'ev', -1)..['rotation'] = 3;
      final restored = restoreEdit(editText(edit), catalogue, stocks);
      expect(sameEdit(restored, edit), isTrue);
    });

    test('a damaged edit or a film not installed is refused', () {
      final edit = defaultEdit(catalogue, 'velvia');
      expect(() => restoreEdit(editText(edit), catalogue, stocks), throwsA(isA<EditProblem>()));
      final bad = withParam(defaultEdit(catalogue), 'ev', 40);
      expect(() => restoreEdit(editText(bad), catalogue, stocks), throwsA(isA<EditProblem>()));
      expect(() => restoreEdit('nonsense', catalogue, stocks), throwsA(isA<EditProblem>()));
      expect(() => restoreEdit(jsonEncode({'version': 2, 'edit': {}}), catalogue, stocks),
          throwsA(isA<EditProblem>()));
    });

    test('a new photograph starts on the starting film and format', () {
      final settings = AppSettings.memory()
        ..set('startingFilm', 'portra400')
        ..set('startingFormat', '120');
      final edit = newPhotoEdit(catalogue, settings, 'gold200', stocks);
      expect(edit['stock'], 'portra400');
      expect(edit['format'], '120');
      settings.set('startingFilm', 'none');
      expect(newPhotoEdit(catalogue, settings, 'gold200', stocks.take(1))['stock'], isNull);
      settings.set('startingFilm', 'missing');
      expect(newPhotoEdit(catalogue, settings, 'gold200', stocks.take(1))['stock'], 'gold200');
    });
  });

  test('Auto Adjust follows the film’s latitude and turns off for a tone edit', () {
    final a = defaultEdit(catalogue, 'gold200');
    expect(autoWindowChanged(a, copyEdit(a)..['stock'] = 'portra400'), isTrue);
    expect(autoWindowChanged(a, copyEdit(a)..['profile'] = {'printCorrection': 1}), isTrue);
    expect(autoFrameChanged(a, copyEdit(a)..['straighten'] = 2), isTrue);
    expect(autoToneChanged(a, withParam(a, 'shadows', .3)), isTrue);
    expect(autoToneChanged(a, withParam(a, 'saturation', .3)), isFalse);
  });
}
