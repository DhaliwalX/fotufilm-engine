import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/negative_document.dart';

void main() {
  const tabs = ['film', 'light', 'develop', 'print'];

  test('a negative adds the Roll; one read as a film keeps what it offers', () {
    expect(documentPanelIds({'stock': 'portra400'}, tabs), tabs);
    expect(documentPanelIds({'stock': null, 'negative': newNegative()}, tabs),
        [...tabs, 'roll']);
    expect(documentPanelIds({'stock': 'gold200', 'negative': newNegative()}, tabs),
        ['film', 'light', 'print', 'roll']);
    expect(offersPanel({'stock': 'gold200', 'negative': newNegative()}, 'crop'), isTrue);
    expect(offersPanel({'stock': 'gold200', 'negative': newNegative()}, 'selective'), isFalse);
    expect(offersPanel({'stock': null, 'negative': newNegative()}, 'selective'), isTrue);
    expect(offersPanel({'stock': 'portra400'}, 'roll'), isFalse);
  });

  test('a new negative opens on the first installed film its base looks like', () {
    final stocks = [
      {'id': 'ektachrome', 'readsNegative': false},
      {'id': 'gold200', 'readsNegative': true},
      {'id': 'portra400', 'readsNegative': true},
    ];
    final scan = {
      'suggestions': [
        {
          'films': [
            {'id': 'missing', 'name': 'Missing'},
            {'id': 'portra400', 'name': 'Portra 400'},
          ],
        },
      ],
    };
    expect(negativeStartingStock(scan, stocks, null), 'portra400');
    expect(negativeStartingStock(null, stocks, 'gold200'), 'gold200');
    expect(negativeStartingStock(null, stocks, 'ektachrome'), 'gold200');
    expect(negativeStartingStock(null, const [], null), isNull);
  });

  test('suggestions are named by their films', () {
    Map films(List<String> names) => {
          'films': [for (final n in names) {'name': n}],
        };
    expect(suggestionName(films(['Gold 200'])), 'Gold 200');
    expect(suggestionName(films(['Vision3 500T', 'CineStill 800T'])),
        'Vision3 500T or CineStill 800T');
    expect(suggestionName(films(['Tri-X 400', 'a', 'b', 'c'])), 'Tri-X 400 and 3 similar films');
  });

  test('a roll is the negatives in the shown frame\'s folder', () {
    final paths = ['/roll/1.tif', '/roll/2.tif', '/other/3.tif', '/roll/4.jpg', 'loose.tif'];
    final negative = [true, true, true, false, true];
    expect(rollOf('/roll/1.tif'), '/roll');
    expect(rollOf('loose.tif'), isNull);
    expect(rollIndices(paths, negative, 0), [0, 1]);
    expect(rollIndices(paths, negative, 3), [0, 1, 3]);
    expect(rollIndices(paths, negative, 4), isEmpty);
  });

  test('a roll\'s colour is the median of its readable frames, red and blue per green', () {
    Map end(List<double> dense) => {'denseEnd': dense};
    expect(rollBalance([end([1.0, 1.0, 1.0])]), isNull);
    expect(rollBalance([end([1.0, 1.0, 1.0]), end([0.01, 1.0, 1.0]), null]), isNull);
    final roll = rollBalance([
      end([1.2, 1.0, 0.8]),
      end([2.6, 2.0, 1.8]),
      end([1.0, 0.5, 0.6]),
      {'denseEnd': null, 'slopes': null},
    ])!;
    expect(roll['frames'], 3);
    expect(roll['colour'][0], closeTo(1.3, 1e-9));
    expect(roll['colour'][1], closeTo(0.9, 1e-9));
    // Its level is the median green of those ends; its steepness needs six frames' steps.
    expect(roll['level'], closeTo(1.0, 1e-9));
    expect(roll.containsKey('slopes'), isFalse);
    final steps = [
      [0.8, 1.1], [0.9, 1.2], [1.0, 1.3], [0.85, 1.25], [0.95, 1.15], [0.9, 1.2],
    ];
    Map stepped(int i) => {
          'denseEnd': [1.2, 1.0, 0.8],
          'slopes': steps[i],
        };
    expect(rollBalance([for (var i = 0; i < 5; i++) stepped(i)])!.containsKey('slopes'), isFalse);
    final contrast = rollBalance([
      for (var i = 0; i < 6; i++) stepped(i),
      {'denseEnd': [1.2, 1.0, 0.8], 'slopes': [double.nan, 1.0]},
    ])!;
    expect(contrast['slopes'][0], closeTo(0.9, 1e-9));
    expect(contrast['slopes'][1], closeTo(1.2, 1e-9));
    expect(contrast['frames'], 7);
  });

  test('a roll keeps the average its frames come to and the colour of its clear film', () {
    const film = [0.44, 0.2, 0.1], tone = [0.52, 0.6, 0.71];
    final measures = <Map?>[
      for (final exposure in const [0.5, 0.8, 1.0, 1.3])
        {
          'denseEnd': [1.0, 1.0, 1.0],
          'average': tone,
          'clear': [for (final v in film) v * exposure],
        },
    ];
    // A frame that read its clear film off its picture, red 0.07 short, and its red that thin.
    final off = [0.44 * math.pow(10, -0.07), 0.2, 0.1];
    measures.add({
      'denseEnd': [1.0, 1.0, 1.0],
      'average': [tone[0] - 0.07, tone[1], tone[2]],
      'clear': off,
    });
    final roll = rollBalance(measures)!;
    expect(roll['clear'][0], closeTo(2.2, 1e-9));
    expect(roll['clear'][1], closeTo(0.5, 1e-9));
    for (var c = 0; c < 3; c++) {
      expect(roll['average'][c], closeTo(tone[c], 1e-9));
    }
    // The frame keeps its level and takes the roll's colour; another film keeps its own.
    final taken = rollClearFilm([for (final v in off) v.toDouble()], (roll['clear'] as List).cast());
    expect(taken[1], off[1]);
    expect(taken[0] / taken[1], closeTo(2.2, 1e-9));
    expect(rollClearFilm(const [0.2, 0.2, 0.2], (roll['clear'] as List).cast()), [0.2, 0.2, 0.2]);
    expect(rollClearFilm(const [0.2, 0.2, 0.2], null), [0.2, 0.2, 0.2]);
    // Measured again on the roll, that frame is read against the roll's clear film: the same roll.
    final again = [...measures]
      ..[4] = {'denseEnd': [1.0, 1.0, 1.0], 'average': tone, 'clear': off, 'border': taken};
    for (var c = 0; c < 3; c++) {
      expect(rollBalance(again)!['average'][c], closeTo(tone[c], 1e-9));
    }
    // One frame's says nothing of a roll's; a frame filled by a colour moves the middle little.
    final few = rollBalance([measures[0], {'denseEnd': [1.0, 1.0, 1.0]}])!;
    expect(few.containsKey('average'), isFalse);
    expect(few.containsKey('clear'), isFalse);
    final sunset = rollBalance([
      ...measures,
      {'denseEnd': [1.0, 1.0, 1.0], 'average': [1.3, 0.7, 0.3]},
    ])!;
    expect(sunset['average'][0] - sunset['average'][1], closeTo(tone[0] - tone[1], 1e-9));
  });

  test('a new negative takes the reading its scan opens with, an older edit keeps its own', () {
    expect(newNegative(), {
      'border': null, 'lightFrame': null, 'roll': null, 'crosstalk': 0, 'scanLight': 'white',
    });
    final fresh = newNegative('screen', 2, true);
    expect(fresh['reading'], 2);
    expect(fresh['crosstalk'], 1);
    // A camera nobody measured starts with the dyes unseparated; LED exposures separate.
    expect(newNegative('white', 2)['crosstalk'], 0);
    expect(newNegative('rgb', 2)['crosstalk'], 1);
    expect(measuredCamera({'camera': {'id': 'sony-ilce-7cm2', 'name': 'SONY ILCE-7CM2'}}), isTrue);
    expect(measuredCamera({'camera': {'id': 'generic'}}), isFalse);
    expect(measuredCamera(null), isFalse);
    expect(fresh['scanLight'], 'screen');
    expect(readsModel(fresh), isTrue);
    expect(readsModel(newNegative()), isFalse);
    expect(readsModel(null), isFalse);
    expect(balanceOf(fresh), 'frame');
    expect(balanceOf({...fresh, 'balance': 'none'}), 'none');
    // A roll measured with the average its frames come to balances its frames unless their
    // edits say otherwise; one kept before that leaves them on themselves.
    final measured = {'colour': [0.9, 1.2], 'frames': 4, 'average': [0.52, 0.6, 0.71]};
    expect(balanceOf({...fresh, 'roll': measured}), 'roll');
    expect(balanceOf({...fresh, 'roll': measured, 'balance': 'frame'}), 'frame');
    expect(balanceOf({...fresh, 'roll': {'colour': [0.9, 1.2], 'frames': 4}}), 'frame');

    // Update Reading: the dyes separated all the way unless the edit said how far, and a frame
    // on its roll stays on it.
    final roll = {'colour': [0.9, 1.2], 'frames': 4};
    final updated = updatedReading(
        {...newNegative('rgb'), 'roll': roll, 'border': [.8, .5, .2]}, 2, separates: true);
    expect(updated['reading'], 2);
    expect(updated['crosstalk'], 1);
    expect(updated['balance'], 'roll');
    expect(updated['roll'], roll);
    expect(updated['border'], [.8, .5, .2]);
    expect(updated['scanLight'], 'rgb');
    final kept = updatedReading({...newNegative(), 'crosstalk': 0.4}, 2, separates: true);
    expect(updatedReading(newNegative(), 2)['crosstalk'], 0);
    expect(kept['crosstalk'], 0.4);
    expect(kept.containsKey('balance'), isFalse);
  });

  test('Show Negative develops the negative without touching the edit', () {
    final stock = {
      'defaultMedium': 'digital',
      'media': [
        {'id': 'digital'},
        {'id': 'negative'},
      ],
    };
    final edit = {'stock': 'gold200', 'medium': null};
    expect(canShowNegative(edit, stock), isTrue);
    expect(negativeViewEdit(edit, stock, true)['medium'], 'negative');
    expect(edit['medium'], isNull);
    expect(negativeViewEdit(edit, stock, false), same(edit));
    expect(canShowNegative({'stock': 'gold200', 'medium': 'negative'}, stock), isFalse);
    expect(canShowNegative({'stock': null}, stock), isFalse);
    expect(canShowNegative(edit, {'media': [{'id': 'digital'}]}), isFalse);
  });

  test('a trichromatic merge says what it left out', () {
    expect(trichromaticNotes(const {}), '');
    expect(
        trichromaticNotes({
          'failures': [
            {'sources': ['a.tif', 'b.tif'], 'reason': 'They do not line up.'},
          ],
          'blanks': ['c.tif'],
          'loose': ['d.tif'],
        }),
        'a.tif, b.tif: They do not line up. Left out as blank: c.tif. '
        'Lined up loosely, so colours may fringe: d.tif.');
  });
}
