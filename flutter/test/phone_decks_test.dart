import 'package:flutter_test/flutter_test.dart';
import 'package:fotufilm_flutter/model/catalogue.dart';
import 'package:fotufilm_flutter/model/edit.dart';
import 'package:fotufilm_flutter/model/editor.dart';
import 'package:fotufilm_flutter/model/phone_decks.dart';
import 'package:fotufilm_flutter/ui/kit/adjustment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Catalogue catalogue;
  setUpAll(() async => catalogue = await Catalogue.load());

  /// An editor showing one photograph with `edit`.
  EditorModel showing(Json Function(Json edit) edit, {double headroom = 1}) {
    final editor = EditorModel(catalogue)..layout.layOut(390);
    editor.documents.add(PhotoDocument(
        path: '/a.png',
        handle: 1,
        width: 600,
        height: 400,
        headroom: headroom,
        history: History(edit(defaultEdit(catalogue)))));
    editor.activeIndex = 0;
    return editor;
  }

  Json onFilm(Json edit) => copyEdit(edit)..['stock'] = 'gold200';

  group('the decks', () {
    test('a photograph has every group, and without a film only the Films page', () {
      final decks = showing((e) => e).layout.decks;
      expect(decks.decks, [
        PhoneDeck.film,
        PhoneDeck.grain,
        PhoneDeck.lens,
        PhoneDeck.print,
        PhoneDeck.light,
        PhoneDeck.select,
        PhoneDeck.crop,
      ]);
      expect(decks.pages(PhoneDeck.film), [DeckPage.films]);
      expect(decks.pages(PhoneDeck.grain), [DeckPage.grain]);
      expect(decks.pages(PhoneDeck.light),
          [DeckPage.exposure, DeckPage.balance, DeckPage.color, DeckPage.grade]);
    });

    test('a film brings its halation, lab and format; Emulsion waits for colour separation', () {
      final decks = showing(onFilm).layout.decks;
      expect(decks.pages(PhoneDeck.film),
          [DeckPage.films, DeckPage.halation, DeckPage.lab, DeckPage.format]);
    });

    test('only a photograph with light above white has HDR Highlights', () {
      final decks = showing(onFilm, headroom: 4).layout.decks;
      expect(decks.pages(PhoneDeck.light).last, DeckPage.hdr);
    });

    test('a scanned negative has its own row', () {
      final decks = showing((e) => copyEdit(e)..['negative'] = {'border': null}).layout.decks;
      expect(decks.decks, [
        PhoneDeck.film,
        PhoneDeck.negative,
        PhoneDeck.print,
        PhoneDeck.light,
        PhoneDeck.crop,
      ]);
      expect(decks.pages(PhoneDeck.film), [DeckPage.films]);
      expect(decks.pages(PhoneDeck.negative), contains(DeckPage.roll));
    });
  });

  group('the sheet', () {
    test('a deck opens on its first page, keeps the page it was left on, and closes', () {
      final decks = showing(onFilm).layout.decks;
      decks.pressed(PhoneDeck.light);
      expect((decks.open, decks.page), (PhoneDeck.light, DeckPage.exposure));
      decks.choosePage(DeckPage.balance);
      decks.pressed(PhoneDeck.light);
      expect(decks.open, isNull);
      decks.pressed(PhoneDeck.light);
      expect(decks.page, DeckPage.balance);
    });

    test('Crop opens the crop tool, and another deck closes it', () {
      final editor = showing(onFilm);
      final decks = editor.layout.decks;
      decks.pressed(PhoneDeck.crop);
      expect(editor.crop.showing, isTrue);
      decks.pressed(PhoneDeck.light);
      expect(editor.crop.showing, isFalse);
      expect(editor.panel.isTool, isFalse);
    });

    test('a deck the photograph no longer offers closes', () {
      final editor = showing(onFilm);
      final decks = editor.layout.decks;
      decks.pressed(PhoneDeck.lens);
      editor.change({'negative': {'border': null}});
      expect(decks.open, isNull);
    });
  });

  test('the readout writes values signed, to the step, with their units', () {
    const ev = SliderRange(min: -3, max: 3, step: .05, def: 0);
    expect(readout(0, ev, 'EV'), '+0.0 EV');
    expect(readout(-0.25, ev, 'EV'), '-0.3 EV');
    const signed = SliderRange(min: -1, max: 1, step: .01, def: 0);
    expect(readout(-0.001, signed, ''), '+0.00');
    expect(readout(.25, signed, ''), '+0.25');
    const grain = SliderRange(min: 0, max: 2, step: .01, def: 1);
    expect(readout(1, grain, '×'), '1.00×');
    const preflash = SliderRange(min: 0, max: .25, step: .005, def: 0);
    expect(readout(.1, preflash, '%', scale: 100), '10%');
    const kelvin = SliderRange(min: 2000, max: 12000, step: 1, def: 6504);
    expect(readout(6504, kelvin, 'K'), '6504 K');
  });
}
