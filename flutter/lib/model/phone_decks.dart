// The phone's editing groups: Film Strip, Grain, Lens, Print and Light & Color along the bottom,
// then Select and Crop, each opening a sheet of pages. A scanned negative has its own row (Film
// Strip, Negative, Print, Light & Color, Crop), and a movie keeps Film Strip, Grain, Print and
// Light & Color. Each page holds sections of the inspector's panels, so the controls behave as
// they do on the desktop.
import 'package:flutter/foundation.dart';

import 'catalogue.dart';
import 'editor.dart';
import 'negative_document.dart';

enum PhoneDeck {
  film('Film Strip', 'fotu.deck.film'),
  negative('Negative', 'fotu.tab.emulsion'),
  grain('Grain', 'fotu.tab.grain'),
  lens('Lens', 'fotu.deck.lens'),
  print('Print', 'fotu.deck.print'),
  light('Light & Color', 'fotu.deck.light'),
  select('Select', 'fotu.tab.local'),
  crop('Crop', 'fotu.tab.geometry');

  const PhoneDeck(this.title, this.glyph);
  final String title, glyph;

  /// The canvas tool a deck opens: the viewer shows the tool's picture while it is open.
  Panel? get tool => switch (this) {
        select => Panel.selective,
        crop => Panel.crop,
        _ => null,
      };
}

enum DeckPage {
  films('Films', 'fotu.tab.films'),
  halation('Halation', 'fotu.tab.halation'),
  emulsion('Emulsion', 'fotu.tab.emulsion'),
  lab('Lab', 'fotu.tab.lab'),
  format('Format', 'fotu.ui.format'),
  negative('Film', 'fotu.tab.films'),
  filmBase('Film Base', 'fotu.tab.source'),
  scanColour('Colour', 'fotu.tab.color'),
  lightSource('Light Source', 'fotu.tab.lamp'),
  roll('Roll', 'fotu.deck.film'),
  grain('Grain', 'fotu.tab.grain'),
  grainModel('Model', 'fotu.deck.controls'),
  grainAdjust('Adjust', 'fotu.deck.controls'),
  filters('Filters', 'fotu.tab.filters'),
  correction('Correction', 'fotu.tab.correction'),
  output('Output', 'fotu.tab.output'),
  printAdjust('Adjust', 'fotu.deck.controls'),
  frame('Frame', 'fotu.deck.frame'),
  lamp('Lamp', 'fotu.tab.lamp'),
  exposure('Exposure', 'fotu.tab.exposure'),
  balance('Balance', 'fotu.tab.balance'),
  color('Color', 'fotu.tab.color'),
  grade('Grade', 'fotu.deck.grade'),
  hdr('HDR Highlights', 'fotu.tab.exposure'),
  select('Select', 'fotu.tab.local'),
  crop('Crop', 'fotu.tab.geometry');

  const DeckPage(this.title, this.glyph);
  final String title, glyph;
}

/// The film grain model's own controls.
const filmGrainFields = [
  'filmGrainSize',
  'filmColourGrain',
  'filmRedLayer',
  'filmGreenLayer',
  'filmBlueLayer',
  'filmScanSoftness',
];

/// The colour separation's controls; the first four tell whether a film has any.
const separationFields = [
  'couplers',
  'couplerReach',
  'couplerSelf',
  'chromaticFringeAmount',
  'chromaticFringeRadius',
];

/// The print's or the screen conversion's own controls.
const printAdjustFields = [
  'printLight',
  'printCorrection',
  'printerRed',
  'printerGreen',
  'printerBlue',
  'negativeViewing',
  'screenGrade',
  'screenExposure',
  'screenCyan',
  'screenMagenta',
  'screenYellow',
  'labScanLook',
  'labScanDodging',
  'highlightDetail',
  'shadowDetail',
];

/// Which decks and pages the shown photograph offers, and which is open.
class PhoneDecks extends ChangeNotifier {
  PhoneDecks(this.editor) {
    editor.addListener(_settle);
  }
  final EditorModel editor;

  /// The open deck; none while the sheet is closed.
  PhoneDeck? open;

  /// The page each deck was left on.
  final Map<PhoneDeck, DeckPage> _pages = {};

  Json get _edit => editor.edit;
  Json? get _stock => editor.selectedStock;
  bool get _hasFilm => _edit['stock'] != null;
  bool get _fixed => (_stock?['profile'] as Map?)?['settings'] == 'fixed';
  List get _available => (_stock?['available'] as List?) ?? const [];

  bool _offers(List<String> fields) =>
      !_fixed && editor.catalogue.profileFields(fields, _edit, _stock).isNotEmpty;

  /// The decks along the bottom, in order.
  List<PhoneDeck> get decks {
    final doc = editor.active;
    final movie = doc?.isMovie ?? false;
    if (isNegative(_edit)) {
      return [
        PhoneDeck.film,
        PhoneDeck.negative,
        if (offersPanel(_edit, 'print')) PhoneDeck.print,
        PhoneDeck.light,
        PhoneDeck.crop,
      ];
    }
    return [
      PhoneDeck.film,
      PhoneDeck.grain,
      if (!movie) PhoneDeck.lens,
      PhoneDeck.print,
      PhoneDeck.light,
      if (!movie) ...[PhoneDeck.select, PhoneDeck.crop],
    ];
  }

  /// A deck's pages for the shown photograph and film.
  List<DeckPage> pages(PhoneDeck deck) {
    final negative = isNegative(_edit);
    return switch (deck) {
      // A negative's films are its only page: the reading is the Negative deck's.
      PhoneDeck.film => [
          DeckPage.films,
          if (_hasFilm && !negative) ...[
            DeckPage.halation,
            if (_available.any(separationFields.take(4).contains)) DeckPage.emulsion,
            DeckPage.lab,
            if (!_fixed) DeckPage.format,
          ],
        ],
      PhoneDeck.negative => [
          DeckPage.negative,
          DeckPage.filmBase,
          DeckPage.scanColour,
          if (editor.negatives.keepsLightFrames) DeckPage.lightSource,
          if (offersPanel(_edit, 'roll')) DeckPage.roll,
        ],
      PhoneDeck.grain => [
          DeckPage.grain,
          if (_hasFilm && _offers(const ['grainModel'])) DeckPage.grainModel,
          if (_hasFilm && _offers(filmGrainFields)) DeckPage.grainAdjust,
        ],
      PhoneDeck.lens => [if (!_fixed) DeckPage.filters, DeckPage.correction],
      PhoneDeck.print => [
          DeckPage.output,
          if (_offers(printAdjustFields)) DeckPage.printAdjust,
          if (!_fixed && editor.active != null) DeckPage.frame,
          if (Catalogue.profileMedium(_edit, _stock)?['enlarger'] == true) DeckPage.lamp,
        ],
      PhoneDeck.light => [
          DeckPage.exposure,
          DeckPage.balance,
          DeckPage.color,
          DeckPage.grade,
          if (!printsNegative(_edit) && (editor.active?.headroom ?? 1) > 1) DeckPage.hdr,
        ],
      PhoneDeck.select => [DeckPage.select],
      PhoneDeck.crop => [DeckPage.crop],
    };
  }

  /// The open deck's page: the one it was left on while the photograph still offers it, else
  /// its first.
  DeckPage? get page {
    final deck = open;
    if (deck == null) return null;
    final offered = pages(deck);
    final left = _pages[deck];
    return left != null && offered.contains(left) ? left : offered.first;
  }

  /// A deck's button: it opens the deck, or closes it when it is the one open.
  void pressed(PhoneDeck deck) => show(open == deck ? null : deck);

  /// Opens `deck` (none closes the sheet), on `page` if given. A tool's deck opens the tool, and
  /// leaving it closes the tool.
  void show(PhoneDeck? deck, {DeckPage? page}) {
    editor.endEdit();
    final leaving = open?.tool;
    open = deck;
    if (deck != null && page != null) _pages[deck] = page;
    final tool = deck?.tool;
    if (tool != null) {
      editor.setPanel(tool);
    } else if (leaving != null && editor.panel == leaving) {
      editor.toggleTool(leaving);
    }
    notifyListeners();
  }

  void choosePage(DeckPage page) {
    final deck = open;
    if (deck == null || page == this.page) return;
    editor.endEdit();
    _pages[deck] = page;
    notifyListeners();
  }

  /// The photograph changed what it offers: a deck it no longer has closes.
  void _settle() {
    final deck = open;
    if (deck != null && !decks.contains(deck)) show(null);
  }
}
