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
    expect(rollBalance([
      [1.0, 1.0, 1.0],
    ]), isNull);
    expect(rollBalance([
      [1.0, 1.0, 1.0],
      [0.01, 1.0, 1.0],
      null,
    ]), isNull);
    final roll = rollBalance([
      [1.2, 1.0, 0.8],
      [2.6, 2.0, 1.8],
      [1.0, 0.5, 0.6],
    ])!;
    expect(roll['frames'], 3);
    expect(roll['colour'][0], closeTo(1.3, 1e-9));
    expect(roll['colour'][1], closeTo(0.9, 1e-9));
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
